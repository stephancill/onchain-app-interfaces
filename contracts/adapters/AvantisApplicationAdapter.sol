// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, IApplicationActions, PreparedAction} from "../IApplicationActions.sol";
import {IApplicationQueries} from "../IApplicationQueries.sol";
import {
    ExternalRequest,
    HttpHeader,
    HttpRequest,
    HttpResponse,
    JsonAbiNode,
    JsonAbiNodeType,
    RequestRequirement,
    ResponseBodyEncoding,
    ResponseTransform,
    ResponseTransformKind
} from "../IExternalRequest.sol";
import {Json} from "../lib/Json.sol";
import {Text} from "../lib/Text.sol";

enum AvantisOrderType {
    MARKET,
    STOP_LIMIT,
    LIMIT,
    MARKET_PNL
}

enum AvantisMarginAction {
    DEPOSIT,
    WITHDRAW
}

struct AvantisExternalQueryResult {
    bytes32 queryId;
    address account;
    bytes32 parametersHash;
    uint16 status;
    bytes32 rawBodyHash;
    bytes body;
    uint256 observedAt;
}

struct AvantisTradeInfo {
    address trader;
    uint256 pairIndex;
    uint256 tradeIndex;
    uint256 collateralUsdc;
    uint256 openPrice;
    bool isLong;
    uint256 leverage;
    uint256 takeProfit;
    uint256 stopLoss;
    uint256 liquidationPrice;
}

struct AvantisOrderInfo {
    address trader;
    uint256 pairIndex;
    uint256 orderIndex;
    uint256 collateralUsdc;
    bool isLong;
    uint256 leverage;
    uint256 takeProfit;
    uint256 stopLoss;
    uint256 price;
    uint256 slippagePercent;
}

struct AvantisPositionsResult {
    address account;
    bytes32 parametersHash;
    bytes32 rawBodyHash;
    AvantisTradeInfo[] trades;
    AvantisOrderInfo[] orders;
    uint256 observedAt;
}

/// @notice The projected JSON_ABI positions body: only API-provided fields.
struct AvantisPositionsBody {
    AvantisTradeInfo[] trades;
    AvantisOrderInfo[] orders;
}

struct AvantisTransaction {
    uint256 chainId;
    address to;
    address from;
    uint256 value;
    bytes callData;
}

struct AvantisAccountState {
    address account;
    uint256 usdcBalance;
    uint256 usdcAllowance;
    address spender;
    uint256 observedAt;
}

struct AvantisOpenTradeParameters {
    uint32 pairIndex;
    bool isLong;
    AvantisOrderType orderType;
    uint256 collateralUsdc;
    uint256 leverage;
    uint256 slippagePercent;
    uint256 openPrice;
    uint256 takeProfit;
    uint256 stopLoss;
    uint256 executionFeeWei;
}

struct AvantisCloseTradeParameters {
    uint32 pairIndex;
    uint32 tradeIndex;
    uint256 collateralToCloseUsdc;
    uint256 expectedPrice;
    uint256 executionFeeWei;
}

struct AvantisLimitOrderParameters {
    uint32 pairIndex;
    uint32 orderIndex;
}

struct AvantisUpdateLimitParameters {
    uint32 pairIndex;
    uint32 orderIndex;
    uint256 price;
    uint256 slippagePercent;
    uint256 takeProfit;
    uint256 stopLoss;
}

struct AvantisIncreasePositionParameters {
    uint32 pairIndex;
    uint32 tradeIndex;
    uint256 additionalCollateralUsdc;
    uint256 leverage;
    uint256 openPrice;
    uint256 slippagePercent;
}

struct AvantisMarginParameters {
    uint32 pairIndex;
    uint32 tradeIndex;
    AvantisMarginAction action;
    uint256 collateralUsdc;
    uint8 priceSourcing;
    uint256 oracleFeeWei;
}

struct AvantisDelegateParameters {
    address delegate;
    uint64 expiry;
}

struct AvantisTrade {
    address trader;
    uint256 pairIndex;
    uint256 index;
    uint256 initialPosToken;
    uint256 positionSizeUSDC;
    uint256 openPrice;
    bool buy;
    uint256 leverage;
    uint256 tp;
    uint256 sl;
    uint256 timestamp;
}

struct AvantisIncreasePositionRequest {
    address trader;
    uint256 pairIndex;
    uint256 index;
    uint256 openPrice;
    uint256 additionalCollateralUsdc;
    uint256 leverage;
}

interface IAvantisErc20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IAvantisTrading {
    function openTrade(AvantisTrade calldata trade, uint8 orderType, uint256 slippagePercent)
        external
        payable
        returns (uint256 orderId);

    function closeTradeMarket(uint256 pairIndex, uint256 tradeIndex, uint256 collateralToClose, uint256 expectedPrice)
        external
        payable;

    function cancelOpenLimitOrder(uint256 pairIndex, uint256 orderIndex) external;

    function updateOpenLimitOrder(
        uint256 pairIndex,
        uint256 orderIndex,
        uint256 price,
        uint256 slippagePercent,
        uint256 takeProfit,
        uint256 stopLoss
    ) external;

    function increasePositionSize(AvantisIncreasePositionRequest calldata request, uint256 slippagePercent) external;

    function updateMargin(
        uint256 pairIndex,
        uint256 tradeIndex,
        uint8 action,
        uint256 collateralUsdc,
        bytes[] calldata priceUpdateData,
        uint8 priceSourcing
    ) external payable;

    function setDelegate(address delegate, uint256 expiry) external;
    function removeDelegate(address delegate) external;
}

interface IAvantisApplicationDescriptors {
    function queryDescriptor(bytes32 queryId) external view returns (bytes memory descriptor);
    function actionDescriptor(bytes32 actionId) external view returns (bytes memory descriptor);
}

/// @notice Descriptor storage is separated because a comprehensive Avantis adapter exceeds EIP-170 when JSON is inline.
contract AvantisApplicationDescriptors is IAvantisApplicationDescriptors {
    function queryDescriptor(bytes32 queryId) external pure returns (bytes memory descriptor) {
        if (queryId == keccak256("avantis.meta")) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"avantis.meta","inputs":{"encoding":"abi","fields":[]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"queryId","abiType":"bytes32","semanticType":"capabilityId"},{"name":"account","abiType":"address","semanticType":"account"},{"name":"parametersHash","abiType":"bytes32"},{"name":"status","abiType":"uint16","semanticType":"httpStatus"},{"name":"rawBodyHash","abiType":"bytes32"},{"name":"body","abiType":"bytes","contentType":"application/json","sensitivity":"public"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"configured-origin"}}'
            );
        }
        if (queryId == keccak256("avantis.markets")) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"avantis.markets","inputs":{"encoding":"abi","fields":[]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"queryId","abiType":"bytes32","semanticType":"capabilityId"},{"name":"account","abiType":"address","semanticType":"account"},{"name":"parametersHash","abiType":"bytes32"},{"name":"status","abiType":"uint16","semanticType":"httpStatus"},{"name":"rawBodyHash","abiType":"bytes32"},{"name":"body","abiType":"bytes","contentType":"application/json","sensitivity":"public"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"configured-origin"}}'
            );
        }
        if (queryId == keccak256("avantis.market")) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"avantis.market","inputs":{"encoding":"abi","fields":[{"name":"pairIndex","abiType":"uint32","semanticType":"marketId"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"queryId","abiType":"bytes32","semanticType":"capabilityId"},{"name":"account","abiType":"address","semanticType":"account"},{"name":"parametersHash","abiType":"bytes32"},{"name":"status","abiType":"uint16","semanticType":"httpStatus"},{"name":"rawBodyHash","abiType":"bytes32"},{"name":"body","abiType":"bytes","contentType":"application/json","sensitivity":"public"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"configured-origin"}}'
            );
        }
        if (queryId == keccak256("avantis.positions")) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"avantis.positions","inputs":{"encoding":"abi","fields":[{"name":"account","abiType":"address","semanticType":"account"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"account","abiType":"address","semanticType":"account"},{"name":"parametersHash","abiType":"bytes32"},{"name":"rawBodyHash","abiType":"bytes32"},{"name":"trades","abiType":"tuple[]","components":[{"name":"trader","abiType":"address","semanticType":"account"},{"name":"pairIndex","abiType":"uint256","semanticType":"marketId"},{"name":"tradeIndex","abiType":"uint256"},{"name":"collateralUsdc","abiType":"uint256","semanticType":"tokenAmount"},{"name":"openPrice","abiType":"uint256","semanticType":"price1e10"},{"name":"isLong","abiType":"bool"},{"name":"leverage","abiType":"uint256","semanticType":"fixedPoint1e10"},{"name":"takeProfit","abiType":"uint256","semanticType":"price1e10"},{"name":"stopLoss","abiType":"uint256","semanticType":"price1e10"},{"name":"liquidationPrice","abiType":"uint256","semanticType":"price1e10"}]},{"name":"orders","abiType":"tuple[]","components":[{"name":"trader","abiType":"address","semanticType":"account"},{"name":"pairIndex","abiType":"uint256","semanticType":"marketId"},{"name":"orderIndex","abiType":"uint256"},{"name":"collateralUsdc","abiType":"uint256","semanticType":"tokenAmount"},{"name":"isLong","abiType":"bool"},{"name":"leverage","abiType":"uint256","semanticType":"fixedPoint1e10"},{"name":"takeProfit","abiType":"uint256","semanticType":"price1e10"},{"name":"stopLoss","abiType":"uint256","semanticType":"price1e10"},{"name":"price","abiType":"uint256","semanticType":"price1e10"},{"name":"slippagePercent","abiType":"uint256","semanticType":"fixedPoint1e10"}]},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"configured-origin"}}'
            );
        }
        if (queryId == keccak256("avantis.account")) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"avantis.account","inputs":{"encoding":"abi","fields":[{"name":"account","abiType":"address","semanticType":"account"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"account","abiType":"address","semanticType":"account"},{"name":"usdcBalance","abiType":"uint256","semanticType":"tokenAmount"},{"name":"usdcAllowance","abiType":"uint256","semanticType":"tokenAmount"},{"name":"spender","abiType":"address"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"onchain"}}'
            );
        }
        revert("unknown query");
    }

    function actionDescriptor(bytes32 actionId) external pure returns (bytes memory descriptor) {
        if (actionId == keccak256("avantis.trade.open")) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"avantis.trade.open","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"pairIndex","abiType":"uint32","semanticType":"marketId"},{"name":"isLong","abiType":"bool"},{"name":"orderType","abiType":"uint8","semanticType":"orderType","enumValues":{"MARKET":0,"STOP_LIMIT":1,"LIMIT":2,"MARKET_PNL":3}},{"name":"collateralUsdc","abiType":"uint256","semanticType":"tokenAmount","minimum":"1"},{"name":"leverage","abiType":"uint256","semanticType":"fixedPoint1e10","minimum":"10000000000","maximum":"10000000000000"},{"name":"slippagePercent","abiType":"uint256","semanticType":"fixedPoint1e10","minimum":"1","maximum":"1000000000000"},{"name":"openPrice","abiType":"uint256","semanticType":"price1e10","minimum":"1"},{"name":"takeProfit","abiType":"uint256","semanticType":"price1e10"},{"name":"stopLoss","abiType":"uint256","semanticType":"price1e10"},{"name":"executionFeeWei","abiType":"uint256","semanticType":"nativeTokenAmount","maximum":"1000000000000000000"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","description":"USDC collateral and execution fee"},{"type":"increase","description":"Leveraged perpetual exposure"}],"execution":{"atomicity":"atomic-required"},"provenance":{"type":"hybrid"}}'
            );
        }
        if (actionId == keccak256("avantis.trade.close")) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"avantis.trade.close","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"pairIndex","abiType":"uint32","semanticType":"marketId"},{"name":"tradeIndex","abiType":"uint32"},{"name":"collateralToCloseUsdc","abiType":"uint256","semanticType":"tokenAmount","minimum":"1"},{"name":"expectedPrice","abiType":"uint256","semanticType":"price1e10","minimum":"1"},{"name":"executionFeeWei","abiType":"uint256","semanticType":"nativeTokenAmount","maximum":"1000000000000000000"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","description":"Open perpetual exposure"},{"type":"increase","description":"USDC payout after settlement"}],"provenance":{"type":"hybrid"}}'
            );
        }
        if (actionId == keccak256("avantis.limit.cancel")) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"avantis.limit.cancel","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"pairIndex","abiType":"uint32","semanticType":"marketId"},{"name":"orderIndex","abiType":"uint32"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","description":"Pending limit order"}],"provenance":{"type":"hybrid"}}'
            );
        }
        if (actionId == keccak256("avantis.limit.update")) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"avantis.limit.update","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"pairIndex","abiType":"uint32","semanticType":"marketId"},{"name":"orderIndex","abiType":"uint32"},{"name":"price","abiType":"uint256","semanticType":"price1e10","minimum":"1"},{"name":"slippagePercent","abiType":"uint256","semanticType":"fixedPoint1e10","minimum":"1","maximum":"1000000000000"},{"name":"takeProfit","abiType":"uint256","semanticType":"price1e10"},{"name":"stopLoss","abiType":"uint256","semanticType":"price1e10"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"set","description":"Pending order trigger, slippage, TP, and SL"}],"provenance":{"type":"hybrid"}}'
            );
        }
        if (actionId == keccak256("avantis.position.increase")) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"avantis.position.increase","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"pairIndex","abiType":"uint32","semanticType":"marketId"},{"name":"tradeIndex","abiType":"uint32"},{"name":"additionalCollateralUsdc","abiType":"uint256","semanticType":"tokenAmount","minimum":"1"},{"name":"leverage","abiType":"uint256","semanticType":"fixedPoint1e10","minimum":"10000000000","maximum":"10000000000000"},{"name":"openPrice","abiType":"uint256","semanticType":"price1e10","minimum":"1"},{"name":"slippagePercent","abiType":"uint256","semanticType":"fixedPoint1e10","minimum":"1","maximum":"1000000000000"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","description":"USDC wallet balance"},{"type":"increase","description":"Existing perpetual exposure"}],"execution":{"atomicity":"atomic-required"},"provenance":{"type":"hybrid"}}'
            );
        }
        if (actionId == keccak256("avantis.margin.update")) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"avantis.margin.update","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"pairIndex","abiType":"uint32","semanticType":"marketId"},{"name":"tradeIndex","abiType":"uint32"},{"name":"action","abiType":"uint8","enumValues":{"DEPOSIT":0,"WITHDRAW":1}},{"name":"collateralUsdc","abiType":"uint256","semanticType":"tokenAmount","minimum":"1"},{"name":"priceSourcing","abiType":"uint8","enumValues":{"HERMES":0,"PRO":1}},{"name":"oracleFeeWei","abiType":"uint256","semanticType":"nativeTokenAmount","maximum":"1000000000000000000"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"set","description":"Position collateral and effective leverage"}],"execution":{"atomicity":"atomic-required"},"provenance":{"type":"hybrid"}}'
            );
        }
        if (actionId == keccak256("avantis.delegate.set")) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"avantis.delegate.set","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"delegate","abiType":"address","semanticType":"account"},{"name":"expiry","abiType":"uint64","semanticType":"timestamp"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"set","description":"Expiring Avantis trading delegate"}],"provenance":{"type":"onchain"}}'
            );
        }
        if (actionId == keccak256("avantis.delegate.remove")) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"avantis.delegate.remove","inputs":{"encoding":"abi","fields":[{"name":"delegate","abiType":"address","semanticType":"account"}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","description":"Avantis delegate authorization"}],"provenance":{"type":"onchain"}}'
            );
        }
        revert("unknown action");
    }
}

/// @notice Experimental comprehensive Avantis application adapter for Base.
contract AvantisApplicationAdapter is IApplicationQueries, IApplicationActions {
    bytes32 public constant META_QUERY = keccak256("avantis.meta");
    bytes32 public constant MARKETS_QUERY = keccak256("avantis.markets");
    bytes32 public constant MARKET_QUERY = keccak256("avantis.market");
    bytes32 public constant POSITIONS_QUERY = keccak256("avantis.positions");
    bytes32 public constant ACCOUNT_QUERY = keccak256("avantis.account");

    bytes32 public constant OPEN_TRADE_ACTION = keccak256("avantis.trade.open");
    bytes32 public constant CLOSE_TRADE_ACTION = keccak256("avantis.trade.close");
    bytes32 public constant CANCEL_LIMIT_ACTION = keccak256("avantis.limit.cancel");
    bytes32 public constant UPDATE_LIMIT_ACTION = keccak256("avantis.limit.update");
    bytes32 public constant INCREASE_POSITION_ACTION = keccak256("avantis.position.increase");
    bytes32 public constant UPDATE_MARGIN_ACTION = keccak256("avantis.margin.update");
    bytes32 public constant SET_DELEGATE_ACTION = keccak256("avantis.delegate.set");
    bytes32 public constant REMOVE_DELEGATE_ACTION = keccak256("avantis.delegate.remove");

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant TRADING = 0x44914408af82bC9983bbb330e3578E1105e11d4e;
    address public constant TRADING_STORAGE = 0x8a311D7048c35985aa31C131B9A13e03a5f7422d;
    uint256 public constant CHAIN_ID = 8453;
    uint256 public constant SCALE = 1e10;
    uint256 public constant MAX_LEVERAGE = 1_000 * SCALE;
    uint256 public constant MAX_PERCENT = 100 * SCALE;
    uint256 public constant MAX_NATIVE_VALUE = 1 ether;
    uint256 public constant MAX_RESPONSE_BYTES = 512_000;
    uint256 public constant PREPARATION_VALIDITY = 5 minutes;

    string public txBuilderBaseUrl;
    IAvantisApplicationDescriptors public immutable descriptors;

    error UnknownQuery(bytes32 queryId);
    error UnknownAction(bytes32 actionId);
    error InvalidParameters();
    error InvalidApiResponse(uint16 status);
    error InvalidTransaction();
    error InsufficientUsdcBalance(uint256 available, uint256 required);

    constructor(string memory txBuilderBaseUrl_) {
        if (bytes(txBuilderBaseUrl_).length == 0) revert InvalidParameters();
        txBuilderBaseUrl = txBuilderBaseUrl_;
        descriptors = new AvantisApplicationDescriptors();
    }

    function queries() external pure returns (bytes32[] memory queryIds) {
        queryIds = new bytes32[](5);
        queryIds[0] = META_QUERY;
        queryIds[1] = MARKETS_QUERY;
        queryIds[2] = MARKET_QUERY;
        queryIds[3] = POSITIONS_QUERY;
        queryIds[4] = ACCOUNT_QUERY;
    }

    function queryDescriptor(bytes32 queryId) external view returns (bytes memory descriptor) {
        if (!_knownQuery(queryId)) revert UnknownQuery(queryId);
        return descriptors.queryDescriptor(queryId);
    }

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory result) {
        if (queryId == ACCOUNT_QUERY) {
            address account = abi.decode(parameters, (address));
            _validateAccount(account);
            return abi.encode(
                AvantisAccountState({
                    account: account,
                    usdcBalance: IAvantisErc20(USDC).balanceOf(account),
                    usdcAllowance: IAvantisErc20(USDC).allowance(account, TRADING_STORAGE),
                    spender: TRADING_STORAGE,
                    observedAt: block.timestamp
                })
            );
        }

        address boundAccount;
        string memory path;
        ResponseTransform memory transform;
        if (queryId == META_QUERY) {
            if (parameters.length != 0) revert InvalidParameters();
            path = "/v2/meta";
            transform = _rawTransform();
        } else if (queryId == MARKETS_QUERY) {
            if (parameters.length != 0) revert InvalidParameters();
            path = "/v2/pairs";
            transform = _rawTransform();
        } else if (queryId == MARKET_QUERY) {
            uint32 pairIndex = abi.decode(parameters, (uint32));
            path = string.concat("/v2/pairs/", Text.uintString(pairIndex));
            transform = _rawTransform();
        } else if (queryId == POSITIONS_QUERY) {
            boundAccount = abi.decode(parameters, (address));
            _validateAccount(boundAccount);
            path = string.concat("/v2/positions?trader=", Text.addressString(boundAccount));
            transform = _positionsTransform();
        } else {
            revert UnknownQuery(queryId);
        }
        _revertRequest(
            path,
            transform,
            this.externalQueryCallback.selector,
            abi.encode(queryId, boundAccount, keccak256(parameters))
        );
    }

    function externalQueryCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (bytes memory)
    {
        _validateResponse(response);
        (bytes32 queryId, address account, bytes32 parametersHash) = abi.decode(extraData, (bytes32, address, bytes32));
        if (queryId == ACCOUNT_QUERY || !_knownQuery(queryId)) revert UnknownQuery(queryId);
        if (queryId == POSITIONS_QUERY) {
            _validateAccount(account);
            if (response.bodyEncoding != ResponseBodyEncoding.JSON_ABI) revert InvalidApiResponse(response.status);
            AvantisPositionsBody memory body = abi.decode(response.body, (AvantisPositionsBody));
            for (uint256 i = 0; i < body.trades.length; i++) {
                if (body.trades[i].trader != account) revert InvalidApiResponse(response.status);
            }
            for (uint256 i = 0; i < body.orders.length; i++) {
                if (body.orders[i].trader != account) revert InvalidApiResponse(response.status);
            }
            return abi.encode(
                AvantisPositionsResult({
                    account: account,
                    parametersHash: parametersHash,
                    rawBodyHash: response.rawBodyHash,
                    trades: body.trades,
                    orders: body.orders,
                    observedAt: block.timestamp
                })
            );
        }
        if (account != address(0)) revert InvalidParameters();
        return abi.encode(
            AvantisExternalQueryResult({
                queryId: queryId,
                account: account,
                parametersHash: parametersHash,
                status: response.status,
                rawBodyHash: response.rawBodyHash,
                body: response.body,
                observedAt: block.timestamp
            })
        );
    }

    function actions() external pure returns (bytes32[] memory actionIds) {
        actionIds = new bytes32[](8);
        actionIds[0] = OPEN_TRADE_ACTION;
        actionIds[1] = CLOSE_TRADE_ACTION;
        actionIds[2] = CANCEL_LIMIT_ACTION;
        actionIds[3] = UPDATE_LIMIT_ACTION;
        actionIds[4] = INCREASE_POSITION_ACTION;
        actionIds[5] = UPDATE_MARGIN_ACTION;
        actionIds[6] = SET_DELEGATE_ACTION;
        actionIds[7] = REMOVE_DELEGATE_ACTION;
    }

    function actionDescriptor(bytes32 actionId) external view returns (bytes memory descriptor) {
        if (!_knownAction(actionId)) revert UnknownAction(actionId);
        return descriptors.actionDescriptor(actionId);
    }

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory)
    {
        _validateAccount(account);
        if (actionId == OPEN_TRADE_ACTION) return _prepareOpen(account, parameters);
        if (actionId == CLOSE_TRADE_ACTION) return _prepareClose(account, parameters);
        if (actionId == CANCEL_LIMIT_ACTION) return _prepareCancel(account, parameters);
        if (actionId == UPDATE_LIMIT_ACTION) return _prepareLimitUpdate(account, parameters);
        if (actionId == INCREASE_POSITION_ACTION) return _prepareIncrease(account, parameters);
        if (actionId == UPDATE_MARGIN_ACTION) return _prepareMargin(account, parameters);
        if (actionId == SET_DELEGATE_ACTION) return _prepareSetDelegate(parameters);
        if (actionId == REMOVE_DELEGATE_ACTION) {
            address delegate = abi.decode(parameters, (address));
            if (delegate == address(0)) revert InvalidParameters();
            return _singleCall(abi.encodeCall(IAvantisTrading.removeDelegate, (delegate)));
        }
        revert UnknownAction(actionId);
    }

    function transactionCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (PreparedAction memory)
    {
        _validateResponse(response);
        if (response.bodyEncoding != ResponseBodyEncoding.JSON_ABI) revert InvalidApiResponse(response.status);
        AvantisTransaction memory transaction = abi.decode(response.body, (AvantisTransaction));
        (address account, bytes memory expectedData, uint256 expectedValue, uint256 approvalAmount) =
            abi.decode(extraData, (address, bytes, uint256, uint256));
        _validateAccount(account);
        if (
            transaction.chainId != CHAIN_ID || transaction.to != TRADING || transaction.from != account
                || transaction.value != expectedValue || keccak256(transaction.callData) != keccak256(expectedData)
        ) revert InvalidTransaction();
        return _preparedCalls(account, transaction.callData, expectedValue, approvalAmount);
    }

    function marginCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (PreparedAction memory)
    {
        _validateResponse(response);
        if (response.bodyEncoding != ResponseBodyEncoding.JSON_ABI) revert InvalidApiResponse(response.status);
        AvantisTransaction memory transaction = abi.decode(response.body, (AvantisTransaction));
        (address account, AvantisMarginParameters memory requested) =
            abi.decode(extraData, (address, AvantisMarginParameters));
        _validateAccount(account);
        _validateMargin(requested);
        if (
            transaction.chainId != CHAIN_ID || transaction.to != TRADING || transaction.from != account
                || transaction.value != requested.oracleFeeWei || transaction.callData.length < 228
        ) revert InvalidTransaction();

        bytes memory callData = transaction.callData;
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(callData, 0x20))
        }
        (
            uint256 pairIndex,
            uint256 tradeIndex,
            uint8 action,
            uint256 collateral,
            bytes[] memory updates,
            uint8 source
        ) = abi.decode(Json.slice(callData, 4, callData.length - 4), (uint256, uint256, uint8, uint256, bytes[], uint8));
        if (
            selector != IAvantisTrading.updateMargin.selector || pairIndex != requested.pairIndex
                || tradeIndex != requested.tradeIndex || action != uint8(requested.action)
                || collateral != requested.collateralUsdc || updates.length == 0 || source != requested.priceSourcing
                || keccak256(callData)
                    != keccak256(
                        abi.encodeCall(
                            IAvantisTrading.updateMargin, (pairIndex, tradeIndex, action, collateral, updates, source)
                        )
                    )
        ) revert InvalidTransaction();
        uint256 approvalAmount = requested.action == AvantisMarginAction.DEPOSIT ? requested.collateralUsdc : 0;
        return _preparedCalls(account, callData, requested.oracleFeeWei, approvalAmount);
    }

    function _prepareOpen(address account, bytes calldata parameters) private view returns (PreparedAction memory) {
        AvantisOpenTradeParameters memory requested = abi.decode(parameters, (AvantisOpenTradeParameters));
        _validateTradeValues(
            requested.collateralUsdc,
            requested.leverage,
            requested.slippagePercent,
            requested.openPrice,
            requested.executionFeeWei
        );
        AvantisTrade memory trade = AvantisTrade({
            trader: account,
            pairIndex: requested.pairIndex,
            index: 0,
            initialPosToken: 0,
            positionSizeUSDC: requested.collateralUsdc,
            openPrice: requested.openPrice,
            buy: requested.isLong,
            leverage: requested.leverage,
            tp: requested.takeProfit,
            sl: requested.stopLoss,
            timestamp: 0
        });
        bytes memory expectedData =
            abi.encodeCall(IAvantisTrading.openTrade, (trade, uint8(requested.orderType), requested.slippagePercent));
        string memory path = string.concat(
            "/v2/trade/open?trader=",
            Text.addressString(account),
            "&pairIndex=",
            Text.uintString(requested.pairIndex),
            "&side=",
            requested.isLong ? "long" : "short",
            "&orderType=",
            _orderTypeString(requested.orderType),
            "&collateralUsdc=",
            _fixedPointString(requested.collateralUsdc, 6),
            "&leverage=",
            _fixedPointString(requested.leverage, 10),
            "&slippagePercent=",
            _fixedPointString(requested.slippagePercent, 10),
            "&openPrice=",
            _fixedPointString(requested.openPrice, 10),
            "&takeProfit=",
            _fixedPointString(requested.takeProfit, 10),
            "&stopLoss=",
            _fixedPointString(requested.stopLoss, 10),
            "&executionFeeWei=",
            Text.uintString(requested.executionFeeWei)
        );
        _prepareTransaction(account, path, expectedData, requested.executionFeeWei, requested.collateralUsdc);
    }

    function _prepareClose(address account, bytes calldata parameters) private view returns (PreparedAction memory) {
        AvantisCloseTradeParameters memory requested = abi.decode(parameters, (AvantisCloseTradeParameters));
        if (
            requested.collateralToCloseUsdc == 0 || requested.expectedPrice == 0
                || requested.executionFeeWei > MAX_NATIVE_VALUE
        ) revert InvalidParameters();
        bytes memory expectedData = abi.encodeCall(
            IAvantisTrading.closeTradeMarket,
            (requested.pairIndex, requested.tradeIndex, requested.collateralToCloseUsdc, requested.expectedPrice)
        );
        _prepareTransaction(
            account,
            string.concat(
                "/v2/trade/close?trader=",
                Text.addressString(account),
                "&pairIndex=",
                Text.uintString(requested.pairIndex),
                "&tradeIndex=",
                Text.uintString(requested.tradeIndex),
                "&collateralToCloseUsdc=",
                _fixedPointString(requested.collateralToCloseUsdc, 6),
                "&expectedPrice=",
                _fixedPointString(requested.expectedPrice, 10),
                "&executionFeeWei=",
                Text.uintString(requested.executionFeeWei)
            ),
            expectedData,
            requested.executionFeeWei,
            0
        );
    }

    function _prepareCancel(address account, bytes calldata parameters) private view returns (PreparedAction memory) {
        AvantisLimitOrderParameters memory requested = abi.decode(parameters, (AvantisLimitOrderParameters));
        bytes memory expectedData =
            abi.encodeCall(IAvantisTrading.cancelOpenLimitOrder, (requested.pairIndex, requested.orderIndex));
        _prepareTransaction(
            account,
            string.concat(
                "/v2/limit/cancel?trader=",
                Text.addressString(account),
                "&pairIndex=",
                Text.uintString(requested.pairIndex),
                "&orderIndex=",
                Text.uintString(requested.orderIndex)
            ),
            expectedData,
            0,
            0
        );
    }

    function _prepareLimitUpdate(address account, bytes calldata parameters)
        private
        view
        returns (PreparedAction memory)
    {
        AvantisUpdateLimitParameters memory requested = abi.decode(parameters, (AvantisUpdateLimitParameters));
        if (requested.price == 0 || requested.slippagePercent == 0 || requested.slippagePercent > MAX_PERCENT) {
            revert InvalidParameters();
        }
        bytes memory expectedData = abi.encodeCall(
            IAvantisTrading.updateOpenLimitOrder,
            (
                requested.pairIndex,
                requested.orderIndex,
                requested.price,
                requested.slippagePercent,
                requested.takeProfit,
                requested.stopLoss
            )
        );
        _prepareTransaction(
            account,
            string.concat(
                "/v2/limit/update?trader=",
                Text.addressString(account),
                "&pairIndex=",
                Text.uintString(requested.pairIndex),
                "&orderIndex=",
                Text.uintString(requested.orderIndex),
                "&price=",
                _fixedPointString(requested.price, 10),
                "&slippagePercent=",
                _fixedPointString(requested.slippagePercent, 10),
                "&takeProfit=",
                _fixedPointString(requested.takeProfit, 10),
                "&stopLoss=",
                _fixedPointString(requested.stopLoss, 10)
            ),
            expectedData,
            0,
            0
        );
    }

    function _prepareIncrease(address account, bytes calldata parameters) private view returns (PreparedAction memory) {
        AvantisIncreasePositionParameters memory requested = abi.decode(parameters, (AvantisIncreasePositionParameters));
        _validateTradeValues(
            requested.additionalCollateralUsdc, requested.leverage, requested.slippagePercent, requested.openPrice, 0
        );
        AvantisIncreasePositionRequest memory increase = AvantisIncreasePositionRequest({
            trader: account,
            pairIndex: requested.pairIndex,
            index: requested.tradeIndex,
            openPrice: requested.openPrice,
            additionalCollateralUsdc: requested.additionalCollateralUsdc,
            leverage: requested.leverage
        });
        bytes memory expectedData =
            abi.encodeCall(IAvantisTrading.increasePositionSize, (increase, requested.slippagePercent));
        _prepareTransaction(
            account,
            string.concat(
                "/v2/position/increase?trader=",
                Text.addressString(account),
                "&pairIndex=",
                Text.uintString(requested.pairIndex),
                "&tradeIndex=",
                Text.uintString(requested.tradeIndex),
                "&additionalCollateralUsdc=",
                _fixedPointString(requested.additionalCollateralUsdc, 6),
                "&leverage=",
                _fixedPointString(requested.leverage, 10),
                "&openPrice=",
                _fixedPointString(requested.openPrice, 10),
                "&slippagePercent=",
                _fixedPointString(requested.slippagePercent, 10)
            ),
            expectedData,
            0,
            requested.additionalCollateralUsdc
        );
    }

    function _prepareMargin(address account, bytes calldata parameters) private view returns (PreparedAction memory) {
        AvantisMarginParameters memory requested = abi.decode(parameters, (AvantisMarginParameters));
        _validateMargin(requested);
        if (requested.action == AvantisMarginAction.DEPOSIT) _checkBalance(account, requested.collateralUsdc);
        _revertRequest(
            string.concat(
                "/v2/margin/update?trader=",
                Text.addressString(account),
                "&pairIndex=",
                Text.uintString(requested.pairIndex),
                "&tradeIndex=",
                Text.uintString(requested.tradeIndex),
                "&action=",
                requested.action == AvantisMarginAction.DEPOSIT ? "deposit" : "withdraw",
                "&collateralUsdc=",
                _fixedPointString(requested.collateralUsdc, 6),
                "&priceSourcing=",
                Text.uintString(requested.priceSourcing),
                "&oracleFeeWei=",
                Text.uintString(requested.oracleFeeWei)
            ),
            _transactionTransform(),
            this.marginCallback.selector,
            abi.encode(account, requested)
        );
    }

    function _prepareSetDelegate(bytes calldata parameters) private view returns (PreparedAction memory) {
        AvantisDelegateParameters memory requested = abi.decode(parameters, (AvantisDelegateParameters));
        // forge-lint: disable-next-line(block-timestamp)
        if (requested.delegate == address(0) || requested.expiry <= block.timestamp) revert InvalidParameters();
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: TRADING,
            value: 0,
            data: abi.encodeCall(IAvantisTrading.setDelegate, (requested.delegate, requested.expiry))
        });
        return PreparedAction({calls: calls, validUntil: requested.expiry});
    }

    function _singleCall(bytes memory callData) private pure returns (PreparedAction memory) {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: TRADING, value: 0, data: callData});
        return PreparedAction({calls: calls, validUntil: 0});
    }

    function _prepareTransaction(
        address account,
        string memory path,
        bytes memory expectedData,
        uint256 expectedValue,
        uint256 approvalAmount
    ) private view {
        if (approvalAmount != 0) _checkBalance(account, approvalAmount);
        _revertRequest(
            path,
            _transactionTransform(),
            this.transactionCallback.selector,
            abi.encode(account, expectedData, expectedValue, approvalAmount)
        );
    }

    function _preparedCalls(address account, bytes memory callData, uint256 value, uint256 approvalAmount)
        private
        view
        returns (PreparedAction memory)
    {
        if (approvalAmount != 0) _checkBalance(account, approvalAmount);
        bool approvalRequired =
            approvalAmount != 0 && IAvantisErc20(USDC).allowance(account, TRADING_STORAGE) < approvalAmount;
        Call[] memory calls = new Call[](approvalRequired ? 2 : 1);
        uint256 actionIndex;
        if (approvalRequired) {
            calls[0] = Call({
                target: USDC, value: 0, data: abi.encodeCall(IAvantisErc20.approve, (TRADING_STORAGE, approvalAmount))
            });
            actionIndex = 1;
        }
        calls[actionIndex] = Call({target: TRADING, value: value, data: callData});
        return PreparedAction({calls: calls, validUntil: block.timestamp + PREPARATION_VALIDITY});
    }

    function _validateTradeValues(uint256 collateral, uint256 leverage, uint256 slippage, uint256 price, uint256 value)
        private
        pure
    {
        if (
            collateral == 0 || leverage < SCALE || leverage > MAX_LEVERAGE || slippage == 0 || slippage > MAX_PERCENT
                || price == 0 || value > MAX_NATIVE_VALUE
        ) revert InvalidParameters();
    }

    function _validateMargin(AvantisMarginParameters memory requested) private pure {
        if (requested.collateralUsdc == 0 || requested.priceSourcing > 1 || requested.oracleFeeWei > MAX_NATIVE_VALUE) {
            revert InvalidParameters();
        }
    }

    function _checkBalance(address account, uint256 required) private view {
        uint256 balance = IAvantisErc20(USDC).balanceOf(account);
        if (balance < required) revert InsufficientUsdcBalance(balance, required);
    }

    function _validateAccount(address account) private pure {
        if (account == address(0)) revert InvalidParameters();
    }

    function _knownQuery(bytes32 queryId) private pure returns (bool) {
        return queryId == META_QUERY || queryId == MARKETS_QUERY || queryId == MARKET_QUERY
            || queryId == POSITIONS_QUERY || queryId == ACCOUNT_QUERY;
    }

    function _knownAction(bytes32 actionId) private pure returns (bool) {
        return actionId == OPEN_TRADE_ACTION || actionId == CLOSE_TRADE_ACTION || actionId == CANCEL_LIMIT_ACTION
            || actionId == UPDATE_LIMIT_ACTION || actionId == INCREASE_POSITION_ACTION
            || actionId == UPDATE_MARGIN_ACTION || actionId == SET_DELEGATE_ACTION || actionId == REMOVE_DELEGATE_ACTION;
    }

    function _orderTypeString(AvantisOrderType orderType) private pure returns (string memory) {
        if (orderType == AvantisOrderType.MARKET) return "market";
        if (orderType == AvantisOrderType.STOP_LIMIT) return "stop_limit";
        if (orderType == AvantisOrderType.LIMIT) return "limit";
        return "market_pnl";
    }

    function _fixedPointString(uint256 value, uint256 decimals) private pure returns (string memory) {
        uint256 scale = 10 ** decimals;
        uint256 fraction = value % scale;
        if (fraction == 0) return Text.uintString(value / scale);
        uint256 trailingZeros;
        while (fraction % 10 == 0) {
            fraction /= 10;
            trailingZeros++;
        }
        uint256 fractionDigits = decimals - trailingZeros;
        bytes memory fractionText = bytes(Text.uintString(fraction));
        bytes memory paddedFraction = new bytes(fractionDigits);
        uint256 padding = fractionDigits - fractionText.length;
        for (uint256 i = 0; i < padding; i++) {
            paddedFraction[i] = "0";
        }
        for (uint256 i = 0; i < fractionText.length; i++) {
            paddedFraction[padding + i] = fractionText[i];
        }
        return string.concat(Text.uintString(value / scale), ".", string(paddedFraction));
    }

    function _validateResponse(HttpResponse calldata response) private pure {
        if (response.status != 200 || response.body.length == 0 || response.body.length > MAX_RESPONSE_BYTES) {
            revert InvalidApiResponse(response.status);
        }
    }

    function _revertRequest(
        string memory path,
        ResponseTransform memory transform,
        bytes4 callback,
        bytes memory extraData
    ) private view {
        HttpHeader[] memory headers = new HttpHeader[](1);
        headers[0] = HttpHeader({name: "Accept", value: "application/json"});
        revert ExternalRequest({
            sender: address(this),
            request: HttpRequest({
                url: string.concat(txBuilderBaseUrl, path),
                method: "GET",
                headers: headers,
                body: bytes(""),
                requirements: new RequestRequirement[](0)
            }),
            responseTransform: transform,
            callbackFunction: callback,
            extraData: extraData
        });
    }

    function _rawTransform() private pure returns (ResponseTransform memory transform) {
        JsonAbiNode[] memory nodes = new JsonAbiNode[](0);
        transform = ResponseTransform({kind: ResponseTransformKind.RAW, statusFrom: 0, statusTo: 0, nodes: nodes});
    }

    function _transactionTransform() private pure returns (ResponseTransform memory transform) {
        JsonAbiNode[] memory nodes = new JsonAbiNode[](6);
        nodes[0] = _node(JsonAbiNodeType.TUPLE, "", 5, 0);
        nodes[1] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/data/chainId", 0, 0);
        nodes[2] = _node(JsonAbiNodeType.ADDRESS, "/data/to", 0, 0);
        nodes[3] = _node(JsonAbiNodeType.ADDRESS, "/data/from", 0, 0);
        nodes[4] = _node(JsonAbiNodeType.UINT256_HEX, "/data/value", 0, 0);
        nodes[5] = _node(JsonAbiNodeType.BYTES, "/data/data", 0, 0);
        transform =
            ResponseTransform({kind: ResponseTransformKind.JSON_ABI, statusFrom: 200, statusTo: 299, nodes: nodes});
    }

    function _positionsTransform() private pure returns (ResponseTransform memory transform) {
        JsonAbiNode[] memory nodes = new JsonAbiNode[](25);
        nodes[0] = _node(JsonAbiNodeType.TUPLE, "", 2, 0);
        nodes[1] = _node(JsonAbiNodeType.ARRAY, "/data/trades", 1, 40);
        nodes[2] = _node(JsonAbiNodeType.TUPLE, "", 10, 0);
        nodes[3] = _node(JsonAbiNodeType.ADDRESS, "/trade/trader", 0, 0);
        nodes[4] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/trade/pairIndex", 0, 0);
        nodes[5] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/trade/index", 0, 0);
        nodes[6] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/trade/positionSizeUSDC", 0, 0);
        nodes[7] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/trade/openPrice", 0, 0);
        nodes[8] = _node(JsonAbiNodeType.BOOL, "/trade/buy", 0, 0);
        nodes[9] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/trade/leverage", 0, 0);
        nodes[10] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/trade/tp", 0, 0);
        nodes[11] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/trade/sl", 0, 0);
        nodes[12] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/liquidationPrice", 0, 0);
        nodes[13] = _node(JsonAbiNodeType.ARRAY, "/data/orders", 1, 40);
        nodes[14] = _node(JsonAbiNodeType.TUPLE, "", 10, 0);
        nodes[15] = _node(JsonAbiNodeType.ADDRESS, "/order/trader", 0, 0);
        nodes[16] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/order/pairIndex", 0, 0);
        nodes[17] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/order/index", 0, 0);
        nodes[18] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/order/positionSize", 0, 0);
        nodes[19] = _node(JsonAbiNodeType.BOOL, "/order/buy", 0, 0);
        nodes[20] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/order/leverage", 0, 0);
        nodes[21] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/order/tp", 0, 0);
        nodes[22] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/order/sl", 0, 0);
        nodes[23] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/order/price", 0, 0);
        nodes[24] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/order/slippageP", 0, 0);
        transform =
            ResponseTransform({kind: ResponseTransformKind.JSON_ABI, statusFrom: 200, statusTo: 299, nodes: nodes});
    }

    function _node(JsonAbiNodeType nodeType, string memory pointer, uint16 childCount, uint32 maxItems)
        private
        pure
        returns (JsonAbiNode memory node)
    {
        node = JsonAbiNode({nodeType: nodeType, pointer: pointer, childCount: childCount, maxItems: maxItems});
    }
}

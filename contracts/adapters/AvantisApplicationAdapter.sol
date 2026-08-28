// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, IApplicationActions, PreparedAction} from "../IApplicationActions.sol";
import {IApplicationQueries} from "../IApplicationQueries.sol";
import {ExternalRequest, HttpHeader, HttpRequest, HttpResponse, RequestRequirement} from "../IExternalRequest.sol";
import {Json} from "../lib/Json.sol";
import {Text} from "../lib/Text.sol";

enum AvantisOrderType {
    MARKET,
    STOP_LIMIT,
    LIMIT,
    MARKET_PNL
}

struct AvantisPositionsResult {
    address account;
    uint16 status;
    bytes body;
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
}

/// @notice Experimental Avantis positions and open-trade adapter for Base.
contract AvantisApplicationAdapter is IApplicationQueries, IApplicationActions {
    bytes32 public constant POSITIONS_QUERY = keccak256("avantis.positions");
    bytes32 public constant OPEN_TRADE_ACTION = keccak256("avantis.trade.open");

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant TRADING = 0x44914408af82bC9983bbb330e3578E1105e11d4e;
    address public constant TRADING_STORAGE = 0x8a311D7048c35985aa31C131B9A13e03a5f7422d;
    uint256 public constant CHAIN_ID = 8453;
    uint256 public constant SCALE = 1e10;
    uint256 public constant MAX_LEVERAGE = 1_000 * SCALE;
    uint256 public constant MAX_SLIPPAGE_PERCENT = 100 * SCALE;
    uint256 public constant MAX_EXECUTION_FEE = 1 ether;
    uint256 public constant MAX_RESPONSE_BYTES = 512_000;
    uint256 public constant PREPARATION_VALIDITY = 5 minutes;

    string public coreApiBaseUrl;
    string public txBuilderBaseUrl;

    error UnknownQuery(bytes32 queryId);
    error UnknownAction(bytes32 actionId);
    error InvalidParameters();
    error InvalidApiResponse(uint16 status);
    error InvalidTransaction();
    error InsufficientUsdcBalance(uint256 available, uint256 required);

    constructor(string memory coreApiBaseUrl_, string memory txBuilderBaseUrl_) {
        if (bytes(coreApiBaseUrl_).length == 0 || bytes(txBuilderBaseUrl_).length == 0) {
            revert InvalidParameters();
        }
        coreApiBaseUrl = coreApiBaseUrl_;
        txBuilderBaseUrl = txBuilderBaseUrl_;
    }

    function queries() external pure returns (bytes32[] memory queryIds) {
        queryIds = new bytes32[](1);
        queryIds[0] = POSITIONS_QUERY;
    }

    function queryDescriptor(bytes32 queryId) external pure returns (bytes memory descriptor) {
        if (queryId == POSITIONS_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"avantis.positions","inputs":{"encoding":"abi","fields":[{"name":"account","abiType":"address","semanticType":"account"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"account","abiType":"address","semanticType":"account"},{"name":"status","abiType":"uint16","semanticType":"httpStatus"},{"name":"body","abiType":"bytes","contentType":"application/json","sensitivity":"public"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"configured-origin"}}'
            );
        }
        revert UnknownQuery(queryId);
    }

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory) {
        if (queryId != POSITIONS_QUERY) revert UnknownQuery(queryId);
        address account = abi.decode(parameters, (address));
        if (account == address(0)) revert InvalidParameters();

        _revertRequest(
            HttpRequest({
                url: string.concat(coreApiBaseUrl, "/user-data?trader=", Text.addressString(account)),
                method: "GET",
                headers: _headers(),
                body: bytes(""),
                requirements: new RequestRequirement[](0)
            }),
            this.positionsCallback.selector,
            abi.encode(account)
        );
    }

    function positionsCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (bytes memory)
    {
        _validateResponse(response);
        address account = abi.decode(extraData, (address));
        if (account == address(0)) revert InvalidParameters();
        return abi.encode(
            AvantisPositionsResult({
                account: account, status: response.status, body: response.body, observedAt: block.timestamp
            })
        );
    }

    function actions() external pure returns (bytes32[] memory actionIds) {
        actionIds = new bytes32[](1);
        actionIds[0] = OPEN_TRADE_ACTION;
    }

    function actionDescriptor(bytes32 actionId) external pure returns (bytes memory descriptor) {
        if (actionId == OPEN_TRADE_ACTION) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"avantis.trade.open","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"pairIndex","abiType":"uint32","semanticType":"marketId"},{"name":"isLong","abiType":"bool"},{"name":"orderType","abiType":"uint8","semanticType":"orderType","enumValues":{"MARKET":0,"STOP_LIMIT":1,"LIMIT":2,"MARKET_PNL":3}},{"name":"collateralUsdc","abiType":"uint256","semanticType":"tokenAmount","minimum":"1"},{"name":"leverage","abiType":"uint256","semanticType":"fixedPoint1e10","minimum":"10000000000","maximum":"10000000000000"},{"name":"slippagePercent","abiType":"uint256","semanticType":"fixedPoint1e10","minimum":"1","maximum":"1000000000000"},{"name":"openPrice","abiType":"uint256","semanticType":"price1e10","minimum":"1"},{"name":"takeProfit","abiType":"uint256","semanticType":"price1e10"},{"name":"stopLoss","abiType":"uint256","semanticType":"price1e10"},{"name":"executionFeeWei","abiType":"uint256","semanticType":"nativeTokenAmount","maximum":"1000000000000000000"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","description":"USDC collateral and execution fee"},{"type":"increase","description":"Leveraged Avantis perpetual exposure"}],"execution":{"atomicity":"atomic-required"},"provenance":{"type":"hybrid"}}'
            );
        }
        revert UnknownAction(actionId);
    }

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory)
    {
        if (actionId != OPEN_TRADE_ACTION) revert UnknownAction(actionId);
        AvantisOpenTradeParameters memory trade = abi.decode(parameters, (AvantisOpenTradeParameters));
        _validateParameters(account, trade);

        uint256 balance = IAvantisErc20(USDC).balanceOf(account);
        if (balance < trade.collateralUsdc) revert InsufficientUsdcBalance(balance, trade.collateralUsdc);

        _revertRequest(
            HttpRequest({
                url: _openTradeUrl(account, trade),
                method: "GET",
                headers: _headers(),
                body: bytes(""),
                requirements: new RequestRequirement[](0)
            }),
            this.openTradeCallback.selector,
            abi.encode(account, trade)
        );
    }

    function openTradeCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (PreparedAction memory preparedAction)
    {
        _validateResponse(response);
        (address account, AvantisOpenTradeParameters memory requested) =
            abi.decode(extraData, (address, AvantisOpenTradeParameters));
        _validateParameters(account, requested);

        bytes memory transaction = Json.objectValue(response.body, "data");
        if (
            Json.uintValue(transaction, "chainId") != CHAIN_ID || Json.addressValue(transaction, "to") != TRADING
                || Json.addressValue(transaction, "from") != account
                || Json.hexStringValue(transaction, "value") != requested.executionFeeWei
        ) revert InvalidTransaction();

        bytes memory callData = Json.bytesValue(transaction, "data");
        if (callData.length != 420) revert InvalidTransaction();
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(callData, 0x20))
        }
        (AvantisTrade memory built, uint8 orderType, uint256 slippagePercent) =
            abi.decode(Json.slice(callData, 4, 416), (AvantisTrade, uint8, uint256));
        if (
            selector != IAvantisTrading.openTrade.selector || built.trader != account
                || built.pairIndex != requested.pairIndex || built.index != 0 || built.initialPosToken != 0
                || built.positionSizeUSDC != requested.collateralUsdc || built.openPrice != requested.openPrice
                || built.buy != requested.isLong || built.leverage != requested.leverage
                || built.tp != requested.takeProfit || built.sl != requested.stopLoss || built.timestamp != 0
                || orderType != uint8(requested.orderType) || slippagePercent != requested.slippagePercent
                || keccak256(callData)
                    != keccak256(abi.encodeCall(IAvantisTrading.openTrade, (built, orderType, slippagePercent)))
        ) revert InvalidTransaction();

        bool approvalRequired = IAvantisErc20(USDC).allowance(account, TRADING_STORAGE) < requested.collateralUsdc;
        Call[] memory calls = new Call[](approvalRequired ? 2 : 1);
        uint256 tradeIndex;
        if (approvalRequired) {
            calls[0] = Call({
                target: USDC,
                value: 0,
                data: abi.encodeCall(IAvantisErc20.approve, (TRADING_STORAGE, requested.collateralUsdc))
            });
            tradeIndex = 1;
        }
        calls[tradeIndex] = Call({target: TRADING, value: requested.executionFeeWei, data: callData});
        return PreparedAction({calls: calls, validUntil: block.timestamp + PREPARATION_VALIDITY});
    }

    function _validateParameters(address account, AvantisOpenTradeParameters memory trade) private pure {
        if (
            account == address(0) || trade.collateralUsdc == 0 || trade.leverage < SCALE
                || trade.leverage > MAX_LEVERAGE || trade.slippagePercent == 0
                || trade.slippagePercent > MAX_SLIPPAGE_PERCENT || trade.openPrice == 0
                || trade.executionFeeWei > MAX_EXECUTION_FEE
        ) revert InvalidParameters();
    }

    function _openTradeUrl(address account, AvantisOpenTradeParameters memory trade)
        private
        view
        returns (string memory)
    {
        return string.concat(
            txBuilderBaseUrl,
            "/v2/trade/open?trader=",
            Text.addressString(account),
            "&pairIndex=",
            Text.uintString(trade.pairIndex),
            "&side=",
            trade.isLong ? "long" : "short",
            "&orderType=",
            _orderTypeString(trade.orderType),
            "&collateralUsdc=",
            _fixedPointString(trade.collateralUsdc, 6),
            "&leverage=",
            _fixedPointString(trade.leverage, 10),
            "&slippagePercent=",
            _fixedPointString(trade.slippagePercent, 10),
            "&openPrice=",
            _fixedPointString(trade.openPrice, 10),
            "&takeProfit=",
            _fixedPointString(trade.takeProfit, 10),
            "&stopLoss=",
            _fixedPointString(trade.stopLoss, 10),
            "&executionFeeWei=",
            Text.uintString(trade.executionFeeWei)
        );
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

    function _headers() private pure returns (HttpHeader[] memory headers) {
        headers = new HttpHeader[](1);
        headers[0] = HttpHeader({name: "Accept", value: "application/json"});
    }

    function _revertRequest(HttpRequest memory request, bytes4 callback, bytes memory extraData) private view {
        revert ExternalRequest({
            sender: address(this), request: request, callbackFunction: callback, extraData: extraData
        });
    }
}

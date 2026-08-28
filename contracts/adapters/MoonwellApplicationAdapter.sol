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
    RequestRequirement,
    ResponseTransform,
    ResponseTransformKind
} from "../IExternalRequest.sol";

struct MoonwellExternalQueryResult {
    bytes32 queryId;
    address account;
    uint16 status;
    bytes body;
    uint256 observedAt;
}

struct MoonwellUsdcPosition {
    address account;
    uint256 mTokenBalance;
    uint256 suppliedUnderlying;
    uint256 borrowedUnderlying;
    uint256 exchangeRateMantissa;
    bool collateralEnabled;
    uint256 observedAt;
}

struct MoonwellSupplyParameters {
    uint256 amount;
    bool enableAsCollateral;
}

interface IMoonwellToken {
    function getAccountSnapshot(address account)
        external
        view
        returns (uint256 errorCode, uint256 mTokenBalance, uint256 borrowBalance, uint256 exchangeRateMantissa);

    function mint(uint256 amount) external returns (uint256 errorCode);
}

interface IMoonwellComptroller {
    function checkMembership(address account, address market) external view returns (bool);
    function enterMarkets(address[] calldata markets) external returns (uint256[] memory errorCodes);
}

interface IMoonwellErc20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Experimental hybrid adapter for Moonwell's current Base USDC market.
contract MoonwellApplicationAdapter is IApplicationQueries, IApplicationActions {
    bytes32 public constant POSITIONS_QUERY = keccak256("moonwell.positions");
    bytes32 public constant HEALTH_QUERY = keccak256("moonwell.health");
    bytes32 public constant USDC_POSITION_QUERY = keccak256("moonwell.position.usdc");
    bytes32 public constant SUPPLY_USDC_ACTION = keccak256("moonwell.supply.usdc");

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant M_USDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address public constant COMPTROLLER = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;

    string public apiBaseUrl;

    error UnknownQuery(bytes32 queryId);
    error UnknownAction(bytes32 actionId);
    error InvalidAccount();
    error InvalidAmount();
    error InvalidApiBaseUrl();
    error InvalidApiResponse(uint16 status);
    error SnapshotFailed(uint256 errorCode);
    error InsufficientUsdcBalance(uint256 available, uint256 required);

    constructor(string memory apiBaseUrl_) {
        if (bytes(apiBaseUrl_).length == 0) revert InvalidApiBaseUrl();
        apiBaseUrl = apiBaseUrl_;
    }

    function queries() external pure returns (bytes32[] memory queryIds) {
        queryIds = new bytes32[](3);
        queryIds[0] = POSITIONS_QUERY;
        queryIds[1] = HEALTH_QUERY;
        queryIds[2] = USDC_POSITION_QUERY;
    }

    function queryDescriptor(bytes32 queryId) external pure returns (bytes memory descriptor) {
        if (queryId == POSITIONS_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"moonwell.positions","inputs":{"encoding":"abi","fields":[{"name":"account","abiType":"address","semanticType":"account"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"queryId","abiType":"bytes32","semanticType":"capabilityId"},{"name":"account","abiType":"address","semanticType":"account"},{"name":"status","abiType":"uint16","semanticType":"httpStatus"},{"name":"body","abiType":"bytes","contentType":"application/json","sensitivity":"public"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"configured-origin"}}'
            );
        }
        if (queryId == HEALTH_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"moonwell.health","inputs":{"encoding":"abi","fields":[{"name":"account","abiType":"address","semanticType":"account"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"queryId","abiType":"bytes32","semanticType":"capabilityId"},{"name":"account","abiType":"address","semanticType":"account"},{"name":"status","abiType":"uint16","semanticType":"httpStatus"},{"name":"body","abiType":"bytes","contentType":"application/json","sensitivity":"public"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"configured-origin"}}'
            );
        }
        if (queryId == USDC_POSITION_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"moonwell.position.usdc","inputs":{"encoding":"abi","fields":[{"name":"account","abiType":"address","semanticType":"account"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"account","abiType":"address","semanticType":"account"},{"name":"mTokenBalance","abiType":"uint256","semanticType":"tokenAmount"},{"name":"suppliedUnderlying","abiType":"uint256","semanticType":"tokenAmount"},{"name":"borrowedUnderlying","abiType":"uint256","semanticType":"tokenAmount"},{"name":"exchangeRateMantissa","abiType":"uint256","semanticType":"exchangeRate"},{"name":"collateralEnabled","abiType":"bool"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"onchain"}}'
            );
        }
        revert UnknownQuery(queryId);
    }

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory result) {
        address account = abi.decode(parameters, (address));
        if (account == address(0)) revert InvalidAccount();

        if (queryId == USDC_POSITION_QUERY) return abi.encode(_usdcPosition(account));
        if (queryId == POSITIONS_QUERY) {
            _revertExternalQuery(
                queryId, account, string.concat("/v1/positions/", _addressString(account), "?chain=base&active=true")
            );
        }
        if (queryId == HEALTH_QUERY) {
            _revertExternalQuery(queryId, account, string.concat("/v1/health/", _addressString(account), "?chain=base"));
        }
        revert UnknownQuery(queryId);
    }

    function externalQueryCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (bytes memory result)
    {
        (bytes32 queryId, address account) = abi.decode(extraData, (bytes32, address));
        if (queryId != POSITIONS_QUERY && queryId != HEALTH_QUERY) revert UnknownQuery(queryId);
        if (account == address(0)) revert InvalidAccount();
        if (response.status < 200 || response.status >= 300 || response.body.length == 0) {
            revert InvalidApiResponse(response.status);
        }

        return abi.encode(
            MoonwellExternalQueryResult({
                queryId: queryId,
                account: account,
                status: response.status,
                body: response.body,
                observedAt: block.timestamp
            })
        );
    }

    function actions() external pure returns (bytes32[] memory actionIds) {
        actionIds = new bytes32[](1);
        actionIds[0] = SUPPLY_USDC_ACTION;
    }

    function actionDescriptor(bytes32 actionId) external pure returns (bytes memory descriptor) {
        if (actionId == SUPPLY_USDC_ACTION) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"moonwell.supply.usdc","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"amount","abiType":"uint256","semanticType":"tokenAmount","minimum":"1"},{"name":"enableAsCollateral","abiType":"bool"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","description":"USDC wallet balance"},{"type":"increase","description":"Moonwell supplied USDC"},{"type":"set","description":"USDC collateral membership when requested"}],"execution":{"atomicity":"atomic-required"},"provenance":{"type":"onchain"}}'
            );
        }
        revert UnknownAction(actionId);
    }

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory preparedAction)
    {
        if (actionId != SUPPLY_USDC_ACTION) revert UnknownAction(actionId);
        if (account == address(0)) revert InvalidAccount();
        MoonwellSupplyParameters memory supply = abi.decode(parameters, (MoonwellSupplyParameters));
        if (supply.amount == 0) revert InvalidAmount();

        uint256 balance = IMoonwellErc20(USDC).balanceOf(account);
        if (balance < supply.amount) revert InsufficientUsdcBalance(balance, supply.amount);
        bool approvalRequired = IMoonwellErc20(USDC).allowance(account, M_USDC) < supply.amount;
        bool enterMarketRequired =
            supply.enableAsCollateral && !IMoonwellComptroller(COMPTROLLER).checkMembership(account, M_USDC);

        uint256 callCount = 1 + (approvalRequired ? 1 : 0) + (enterMarketRequired ? 1 : 0);
        Call[] memory calls = new Call[](callCount);
        uint256 callIndex;
        if (approvalRequired) {
            calls[callIndex++] =
                Call({target: USDC, value: 0, data: abi.encodeCall(IMoonwellErc20.approve, (M_USDC, supply.amount))});
        }
        if (enterMarketRequired) {
            address[] memory markets = new address[](1);
            markets[0] = M_USDC;
            calls[callIndex++] = Call({
                target: COMPTROLLER, value: 0, data: abi.encodeCall(IMoonwellComptroller.enterMarkets, (markets))
            });
        }
        calls[callIndex] = Call({target: M_USDC, value: 0, data: abi.encodeCall(IMoonwellToken.mint, (supply.amount))});

        preparedAction = PreparedAction({calls: calls, validUntil: 0});
    }

    function _usdcPosition(address account) private view returns (MoonwellUsdcPosition memory position) {
        (uint256 errorCode, uint256 mTokenBalance, uint256 borrowBalance, uint256 exchangeRate) =
            IMoonwellToken(M_USDC).getAccountSnapshot(account);
        if (errorCode != 0) revert SnapshotFailed(errorCode);
        position = MoonwellUsdcPosition({
            account: account,
            mTokenBalance: mTokenBalance,
            suppliedUnderlying: mTokenBalance * exchangeRate / 1e18,
            borrowedUnderlying: borrowBalance,
            exchangeRateMantissa: exchangeRate,
            collateralEnabled: IMoonwellComptroller(COMPTROLLER).checkMembership(account, M_USDC),
            observedAt: block.timestamp
        });
    }

    function _revertExternalQuery(bytes32 queryId, address account, string memory path) private view {
        HttpHeader[] memory headers = new HttpHeader[](1);
        headers[0] = HttpHeader({name: "Accept", value: "application/json"});
        RequestRequirement[] memory requirements = new RequestRequirement[](0);
        revert ExternalRequest({
            sender: address(this),
            request: HttpRequest({
                url: string.concat(apiBaseUrl, path),
                method: "GET",
                headers: headers,
                body: bytes(""),
                requirements: requirements
            }),
            responseTransform: _rawTransform(),
            callbackFunction: this.externalQueryCallback.selector,
            extraData: abi.encode(queryId, account)
        });
    }

    function _addressString(address account) private pure returns (string memory) {
        bytes20 value = bytes20(account);
        bytes16 symbols = "0123456789abcdef";
        bytes memory output = new bytes(42);
        output[0] = "0";
        output[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            uint8 byteValue = uint8(value[i]);
            output[2 + i * 2] = symbols[byteValue >> 4];
            output[3 + i * 2] = symbols[byteValue & 0x0f];
        }
        return string(output);
    }

    function _rawTransform() private pure returns (ResponseTransform memory transform) {
        JsonAbiNode[] memory nodes = new JsonAbiNode[](0);
        transform = ResponseTransform({kind: ResponseTransformKind.RAW, statusFrom: 0, statusTo: 0, nodes: nodes});
    }
}

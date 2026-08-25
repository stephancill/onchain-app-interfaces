// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, IApplicationActions, PreparedAction} from "../IApplicationActions.sol";
import {IApplicationQueries} from "../IApplicationQueries.sol";
import {ExternalRequest, HttpHeader, HttpRequest, HttpResponse, RequestRequirement} from "../IExternalRequest.sol";

struct MoonwellExternalQueryResult {
    bytes32 queryId;
    address account;
    uint16 status;
    bytes body;
    uint256 observedAt;
}

struct MoonwellPosition {
    address account;
    address market;
    address underlying;
    uint256 mTokenBalance;
    uint256 suppliedUnderlying;
    uint256 borrowedUnderlying;
    uint256 exchangeRateMantissa;
    bool collateralEnabled;
    uint256 observedAt;
}

struct MoonwellMarketResult {
    address market;
    address underlying;
    uint256 observedAt;
}

struct MoonwellSupplyParameters {
    address market;
    uint256 amount;
    bool enableAsCollateral;
}

interface IMoonwellToken {
    function comptroller() external view returns (address);
    function underlying() external view returns (address);
    function getAccountSnapshot(address account)
        external
        view
        returns (uint256 errorCode, uint256 mTokenBalance, uint256 borrowBalance, uint256 exchangeRateMantissa);

    function mint(uint256 amount) external returns (uint256 errorCode);
}

interface IMoonwellComptroller {
    function getAllMarkets() external view returns (address[] memory markets_);
    function markets(address market) external view returns (bool isListed, uint256 collateralFactorMantissa);
    function checkMembership(address account, address market) external view returns (bool);
    function enterMarkets(address[] calldata markets) external returns (uint256[] memory errorCodes);
}

interface IMoonwellErc20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Experimental hybrid adapter for listed Moonwell ERC-20 markets on Base.
contract MoonwellApplicationAdapter is IApplicationQueries, IApplicationActions {
    bytes32 public constant MARKET_QUERY = keccak256("moonwell.market");
    bytes32 public constant POSITIONS_QUERY = keccak256("moonwell.positions");
    bytes32 public constant HEALTH_QUERY = keccak256("moonwell.health");
    bytes32 public constant POSITION_QUERY = keccak256("moonwell.position");
    bytes32 public constant SUPPLY_ACTION = keccak256("moonwell.supply");

    address public constant COMPTROLLER = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;

    string public apiBaseUrl;

    error UnknownQuery(bytes32 queryId);
    error UnknownAction(bytes32 actionId);
    error InvalidAccount();
    error InvalidMarket(address market);
    error MarketNotFound(address underlying);
    error AmbiguousMarket(address underlying, address firstMarket, address secondMarket);
    error InvalidAmount();
    error InvalidApiBaseUrl();
    error InvalidApiResponse(uint16 status);
    error SnapshotFailed(uint256 errorCode);
    error InsufficientBalance(uint256 available, uint256 required);

    constructor(string memory apiBaseUrl_) {
        if (bytes(apiBaseUrl_).length == 0) revert InvalidApiBaseUrl();
        apiBaseUrl = apiBaseUrl_;
    }

    function queries() external pure returns (bytes32[] memory queryIds) {
        queryIds = new bytes32[](4);
        queryIds[0] = POSITIONS_QUERY;
        queryIds[1] = HEALTH_QUERY;
        queryIds[2] = POSITION_QUERY;
        queryIds[3] = MARKET_QUERY;
    }

    function queryDescriptor(bytes32 queryId) external pure returns (bytes memory descriptor) {
        if (queryId == MARKET_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"moonwell.market","inputs":{"encoding":"abi","fields":[{"name":"underlying","abiType":"address","semanticType":"erc20"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"market","abiType":"address","semanticType":"contract"},{"name":"underlying","abiType":"address","semanticType":"erc20"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"onchain"}}'
            );
        }
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
        if (queryId == POSITION_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"moonwell.position","inputs":{"encoding":"abi","fields":[{"name":"account","abiType":"address","semanticType":"account"},{"name":"market","abiType":"address","semanticType":"contract"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"account","abiType":"address","semanticType":"account"},{"name":"market","abiType":"address","semanticType":"contract"},{"name":"underlying","abiType":"address","semanticType":"erc20"},{"name":"mTokenBalance","abiType":"uint256","semanticType":"tokenAmount","assetField":"result.market"},{"name":"suppliedUnderlying","abiType":"uint256","semanticType":"tokenAmount","assetField":"result.underlying"},{"name":"borrowedUnderlying","abiType":"uint256","semanticType":"tokenAmount","assetField":"result.underlying"},{"name":"exchangeRateMantissa","abiType":"uint256","semanticType":"exchangeRate"},{"name":"collateralEnabled","abiType":"bool"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"onchain"}}'
            );
        }
        revert UnknownQuery(queryId);
    }

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory result) {
        if (queryId == MARKET_QUERY) {
            address underlying = abi.decode(parameters, (address));
            return abi.encode(_market(underlying));
        }
        if (queryId == POSITION_QUERY) {
            (address account, address market) = abi.decode(parameters, (address, address));
            if (account == address(0)) revert InvalidAccount();
            return abi.encode(_position(account, market));
        }
        if (queryId == POSITIONS_QUERY) {
            address account = _account(parameters);
            _revertExternalQuery(
                queryId, account, string.concat("/v1/positions/", _addressString(account), "?chain=base&active=true")
            );
        }
        if (queryId == HEALTH_QUERY) {
            address account = _account(parameters);
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
        actionIds[0] = SUPPLY_ACTION;
    }

    function actionDescriptor(bytes32 actionId) external pure returns (bytes memory descriptor) {
        if (actionId == SUPPLY_ACTION) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"moonwell.supply","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"market","abiType":"address","semanticType":"contract"},{"name":"amount","abiType":"uint256","semanticType":"tokenAmount","minimum":"1"},{"name":"enableAsCollateral","abiType":"bool"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","description":"Underlying wallet balance"},{"type":"increase","description":"Moonwell supplied position"},{"type":"set","description":"Market collateral membership when requested"}],"execution":{"atomicity":"atomic-required"},"provenance":{"type":"onchain"}}'
            );
        }
        revert UnknownAction(actionId);
    }

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory preparedAction)
    {
        if (actionId != SUPPLY_ACTION) revert UnknownAction(actionId);
        if (account == address(0)) revert InvalidAccount();
        MoonwellSupplyParameters memory supply = abi.decode(parameters, (MoonwellSupplyParameters));
        if (supply.amount == 0) revert InvalidAmount();
        address underlying = _underlying(supply.market);

        uint256 balance = IMoonwellErc20(underlying).balanceOf(account);
        if (balance < supply.amount) revert InsufficientBalance(balance, supply.amount);
        bool approvalRequired = IMoonwellErc20(underlying).allowance(account, supply.market) < supply.amount;
        bool enterMarketRequired =
            supply.enableAsCollateral && !IMoonwellComptroller(COMPTROLLER).checkMembership(account, supply.market);

        uint256 callCount = 1 + (approvalRequired ? 1 : 0) + (enterMarketRequired ? 1 : 0);
        Call[] memory calls = new Call[](callCount);
        uint256 callIndex;
        if (approvalRequired) {
            calls[callIndex++] = Call({
                target: underlying,
                value: 0,
                data: abi.encodeCall(IMoonwellErc20.approve, (supply.market, supply.amount))
            });
        }
        if (enterMarketRequired) {
            address[] memory markets = new address[](1);
            markets[0] = supply.market;
            calls[callIndex++] = Call({
                target: COMPTROLLER, value: 0, data: abi.encodeCall(IMoonwellComptroller.enterMarkets, (markets))
            });
        }
        calls[callIndex] =
            Call({target: supply.market, value: 0, data: abi.encodeCall(IMoonwellToken.mint, (supply.amount))});

        preparedAction = PreparedAction({calls: calls, validUntil: 0});
    }

    function _position(address account, address market) private view returns (MoonwellPosition memory position) {
        address underlying = _underlying(market);
        (uint256 errorCode, uint256 mTokenBalance, uint256 borrowBalance, uint256 exchangeRate) =
            IMoonwellToken(market).getAccountSnapshot(account);
        if (errorCode != 0) revert SnapshotFailed(errorCode);
        position = MoonwellPosition({
            account: account,
            market: market,
            underlying: underlying,
            mTokenBalance: mTokenBalance,
            suppliedUnderlying: mTokenBalance * exchangeRate / 1e18,
            borrowedUnderlying: borrowBalance,
            exchangeRateMantissa: exchangeRate,
            collateralEnabled: IMoonwellComptroller(COMPTROLLER).checkMembership(account, market),
            observedAt: block.timestamp
        });
    }

    function _market(address underlying) private view returns (MoonwellMarketResult memory result) {
        if (underlying == address(0) || underlying.code.length == 0) revert MarketNotFound(underlying);
        address[] memory markets = IMoonwellComptroller(COMPTROLLER).getAllMarkets();
        address match_;
        for (uint256 i = 0; i < markets.length; i++) {
            address candidate = markets[i];
            (bool isListed,) = IMoonwellComptroller(COMPTROLLER).markets(candidate);
            if (
                isListed && IMoonwellToken(candidate).comptroller() == COMPTROLLER
                    && IMoonwellToken(candidate).underlying() == underlying
            ) {
                if (match_ != address(0)) revert AmbiguousMarket(underlying, match_, candidate);
                match_ = candidate;
            }
        }
        if (match_ == address(0)) revert MarketNotFound(underlying);
        result = MoonwellMarketResult({market: match_, underlying: underlying, observedAt: block.timestamp});
    }

    function _underlying(address market) private view returns (address underlying) {
        if (market == address(0) || market.code.length == 0) revert InvalidMarket(market);
        IMoonwellToken candidate = IMoonwellToken(market);
        if (candidate.comptroller() != COMPTROLLER) revert InvalidMarket(market);
        (bool isListed,) = IMoonwellComptroller(COMPTROLLER).markets(market);
        if (!isListed) revert InvalidMarket(market);
        underlying = candidate.underlying();
        if (underlying == address(0) || underlying.code.length == 0) revert InvalidMarket(market);
    }

    function _account(bytes calldata parameters) private pure returns (address account) {
        account = abi.decode(parameters, (address));
        if (account == address(0)) revert InvalidAccount();
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
}

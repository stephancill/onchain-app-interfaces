// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, PreparedAction} from "../contracts/IApplicationActions.sol";
import {HttpHeader, HttpResponse} from "../contracts/IExternalRequest.sol";
import {
    IMoonwellErc20,
    MoonwellApplicationAdapter,
    MoonwellExternalQueryResult,
    MoonwellMarketResult,
    MoonwellPosition,
    MoonwellSupplyParameters
} from "../contracts/adapters/MoonwellApplicationAdapter.sol";

interface MoonwellVm {
    function startPrank(address msgSender) external;
    function stopPrank() external;
}

contract MoonwellApplicationAdapterTest {
    MoonwellVm internal constant vm = MoonwellVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant M_USDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address internal constant MORPHO = 0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842;
    address internal constant M_MORPHO = 0x6308204872BdB7432dF97b04B42443c714904F3E;
    MoonwellApplicationAdapter internal adapter = new MoonwellApplicationAdapter("https://api.moonwell.fi");

    function testDiscoversQueriesAndActions() external view {
        bytes32[] memory queryIds = adapter.queries();
        bytes32[] memory actionIds = adapter.actions();
        require(queryIds.length == 4, "wrong query count");
        require(queryIds[0] == adapter.POSITIONS_QUERY(), "missing positions query");
        require(queryIds[1] == adapter.HEALTH_QUERY(), "missing health query");
        require(queryIds[2] == adapter.POSITION_QUERY(), "missing position query");
        require(queryIds[3] == adapter.MARKET_QUERY(), "missing market search query");
        require(actionIds.length == 1, "wrong action count");
        require(actionIds[0] == adapter.SUPPLY_ACTION(), "missing supply action");
    }

    function testFindsMarketsByUnderlying() external view {
        if (!_forkAvailable()) return;

        address[2] memory underlyings = [USDC, MORPHO];
        address[2] memory markets = [M_USDC, M_MORPHO];
        for (uint256 i = 0; i < underlyings.length; i++) {
            MoonwellMarketResult memory result =
                abi.decode(adapter.query(adapter.MARKET_QUERY(), abi.encode(underlyings[i])), (MoonwellMarketResult));
            require(result.underlying == underlyings[i], "wrong underlying");
            require(result.market == markets[i], "wrong market");
        }
    }

    function testRejectsZeroAccount() external view {
        (bool success,) = address(adapter)
            .staticcall(abi.encodeCall(adapter.query, (adapter.POSITION_QUERY(), abi.encode(address(0), M_USDC))));
        require(!success, "zero account should fail");
    }

    function testRejectsInvalidMarket() external view {
        (bool success,) = address(adapter)
            .staticcall(abi.encodeCall(adapter.query, (adapter.POSITION_QUERY(), abi.encode(address(1), address(1)))));
        require(!success, "invalid market should fail");
    }

    function testExternalCallbackBindsQueryAndAccount() external view {
        address account = address(0xbeef);
        HttpHeader[] memory headers = new HttpHeader[](0);
        HttpResponse memory response = HttpResponse({status: 200, headers: headers, body: bytes('{"success":true}')});
        MoonwellExternalQueryResult memory result = abi.decode(
            adapter.externalQueryCallback(response, abi.encode(adapter.HEALTH_QUERY(), account)),
            (MoonwellExternalQueryResult)
        );

        require(result.queryId == adapter.HEALTH_QUERY(), "wrong query ID");
        require(result.account == account, "wrong account");
        require(result.status == 200, "wrong status");
        require(keccak256(result.body) == keccak256(response.body), "wrong body");
    }

    function testExternalCallbackRejectsHttpError() external view {
        HttpHeader[] memory headers = new HttpHeader[](0);
        HttpResponse memory response = HttpResponse({status: 500, headers: headers, body: bytes("failure")});
        (bool success,) = address(adapter)
            .staticcall(
                abi.encodeCall(
                    adapter.externalQueryCallback, (response, abi.encode(adapter.HEALTH_QUERY(), address(0xbeef)))
                )
            );
        require(!success, "HTTP error should fail");
    }

    function testReadsLivePositionsAcrossMarkets() external view {
        if (!_forkAvailable()) return;

        address account = address(1);
        address[2] memory markets = [M_USDC, M_MORPHO];
        address[2] memory underlyings = [USDC, MORPHO];
        for (uint256 i = 0; i < markets.length; i++) {
            MoonwellPosition memory position = abi.decode(
                adapter.query(adapter.POSITION_QUERY(), abi.encode(account, markets[i])), (MoonwellPosition)
            );
            require(position.account == account, "wrong account");
            require(position.market == markets[i], "wrong market");
            require(position.underlying == underlyings[i], "wrong underlying");
            require(
                position.suppliedUnderlying == position.mTokenBalance * position.exchangeRateMantissa / 1e18,
                "wrong supplied amount"
            );
            // forge-lint: disable-next-line(block-timestamp)
            require(position.observedAt == block.timestamp, "wrong observation time");
        }
    }

    function testPreparesSupplyWithoutCollateralEntry() external view {
        if (!_forkAvailable()) return;

        MoonwellSupplyParameters memory parameters =
            MoonwellSupplyParameters({market: M_USDC, amount: 1_000_000, enableAsCollateral: false});
        PreparedAction memory prepared = adapter.prepare(adapter.SUPPLY_ACTION(), address(1), abi.encode(parameters));

        require(prepared.calls.length == 2, "expected approval and mint");
        require(prepared.calls[0].target == USDC, "wrong approval target");
        require(prepared.calls[1].target == M_USDC, "wrong mint target");
        require(prepared.validUntil == 0, "unexpected expiry");
    }

    function testPreparesSupplyForSecondMarket() external view {
        if (!_forkAvailable()) return;

        MoonwellSupplyParameters memory parameters =
            MoonwellSupplyParameters({market: M_MORPHO, amount: 1, enableAsCollateral: false});
        PreparedAction memory prepared = adapter.prepare(adapter.SUPPLY_ACTION(), M_MORPHO, abi.encode(parameters));

        require(prepared.calls.length >= 1 && prepared.calls.length <= 2, "unexpected call count");
        require(prepared.calls[prepared.calls.length - 1].target == M_MORPHO, "wrong mint target");
        if (prepared.calls.length == 2) require(prepared.calls[0].target == MORPHO, "wrong approval target");
    }

    function testExecutesSupplyAndObservesPositionOnFork() external {
        if (!_forkAvailable()) return;

        address account = address(1);
        uint256 amount = 1_000_000;
        uint256 balanceBefore = IMoonwellErc20(USDC).balanceOf(account);
        MoonwellPosition memory beforePosition =
            abi.decode(adapter.query(adapter.POSITION_QUERY(), abi.encode(account, M_USDC)), (MoonwellPosition));
        MoonwellSupplyParameters memory parameters =
            MoonwellSupplyParameters({market: M_USDC, amount: amount, enableAsCollateral: true});
        PreparedAction memory prepared = adapter.prepare(adapter.SUPPLY_ACTION(), account, abi.encode(parameters));
        require(prepared.calls.length == 3, "expected approval, enter, and mint");

        vm.startPrank(account);
        for (uint256 i = 0; i < prepared.calls.length; i++) {
            Call memory preparedCall = prepared.calls[i];
            (bool success, bytes memory returnData) =
                preparedCall.target.call{value: preparedCall.value}(preparedCall.data);
            require(success, "prepared call reverted");
            if (preparedCall.target == USDC) {
                require(abi.decode(returnData, (bool)), "approval failed");
            } else if (preparedCall.target == adapter.COMPTROLLER()) {
                uint256[] memory errorCodes = abi.decode(returnData, (uint256[]));
                require(errorCodes.length == 1 && errorCodes[0] == 0, "enter market failed");
            } else {
                require(abi.decode(returnData, (uint256)) == 0, "mint failed");
            }
        }
        vm.stopPrank();

        MoonwellPosition memory afterPosition =
            abi.decode(adapter.query(adapter.POSITION_QUERY(), abi.encode(account, M_USDC)), (MoonwellPosition));
        require(IMoonwellErc20(USDC).balanceOf(account) == balanceBefore - amount, "USDC not supplied");
        require(afterPosition.mTokenBalance > beforePosition.mTokenBalance, "mToken not received");
        require(afterPosition.suppliedUnderlying > beforePosition.suppliedUnderlying, "position unchanged");
        require(afterPosition.collateralEnabled, "collateral not enabled");
    }

    function _forkAvailable() private view returns (bool) {
        return USDC.code.length != 0 && M_USDC.code.length != 0 && adapter.COMPTROLLER().code.length != 0;
    }
}

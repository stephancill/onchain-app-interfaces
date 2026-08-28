// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, PreparedAction} from "../contracts/IApplicationActions.sol";
import {HttpHeader, HttpResponse, ResponseBodyEncoding} from "../contracts/IExternalRequest.sol";
import {
    IMoonwellErc20,
    MoonwellApplicationAdapter,
    MoonwellExternalQueryResult,
    MoonwellSupplyParameters,
    MoonwellUsdcPosition
} from "../contracts/adapters/MoonwellApplicationAdapter.sol";

interface MoonwellVm {
    function startPrank(address msgSender) external;
    function stopPrank() external;
}

contract MoonwellApplicationAdapterTest {
    MoonwellVm internal constant vm = MoonwellVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    MoonwellApplicationAdapter internal adapter = new MoonwellApplicationAdapter("https://api.moonwell.fi");

    function testDiscoversQueriesAndActions() external view {
        bytes32[] memory queryIds = adapter.queries();
        bytes32[] memory actionIds = adapter.actions();
        require(queryIds.length == 3, "wrong query count");
        require(queryIds[0] == adapter.POSITIONS_QUERY(), "missing positions query");
        require(queryIds[1] == adapter.HEALTH_QUERY(), "missing health query");
        require(queryIds[2] == adapter.USDC_POSITION_QUERY(), "missing USDC query");
        require(actionIds.length == 1, "wrong action count");
        require(actionIds[0] == adapter.SUPPLY_USDC_ACTION(), "missing supply action");
    }

    function testRejectsZeroAccount() external view {
        (bool success,) = address(adapter)
            .staticcall(abi.encodeCall(adapter.query, (adapter.USDC_POSITION_QUERY(), abi.encode(address(0)))));
        require(!success, "zero account should fail");
    }

    function testExternalCallbackBindsQueryAndAccount() external view {
        address account = address(0xbeef);
        HttpHeader[] memory headers = new HttpHeader[](0);
        HttpResponse memory response = HttpResponse({
            status: 200,
            headers: headers,
            rawBodyHash: keccak256(bytes('{"success":true}')),
            bodyEncoding: ResponseBodyEncoding.RAW,
            body: bytes('{"success":true}')
        });
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
        HttpResponse memory response = HttpResponse({
            status: 500,
            headers: headers,
            rawBodyHash: keccak256(bytes("failure")),
            bodyEncoding: ResponseBodyEncoding.RAW,
            body: bytes("failure")
        });
        (bool success,) = address(adapter)
            .staticcall(
                abi.encodeCall(
                    adapter.externalQueryCallback, (response, abi.encode(adapter.HEALTH_QUERY(), address(0xbeef)))
                )
            );
        require(!success, "HTTP error should fail");
    }

    function testReadsLiveUsdcPosition() external view {
        if (!_forkAvailable()) return;

        address account = address(1);
        MoonwellUsdcPosition memory position =
            abi.decode(adapter.query(adapter.USDC_POSITION_QUERY(), abi.encode(account)), (MoonwellUsdcPosition));
        require(position.account == account, "wrong account");
        require(
            position.suppliedUnderlying == position.mTokenBalance * position.exchangeRateMantissa / 1e18,
            "wrong supplied amount"
        );
        // forge-lint: disable-next-line(block-timestamp)
        require(position.observedAt == block.timestamp, "wrong observation time");
    }

    function testPreparesSupplyWithoutCollateralEntry() external view {
        if (!_forkAvailable()) return;

        MoonwellSupplyParameters memory parameters =
            MoonwellSupplyParameters({amount: 1_000_000, enableAsCollateral: false});
        PreparedAction memory prepared =
            adapter.prepare(adapter.SUPPLY_USDC_ACTION(), address(1), abi.encode(parameters));

        require(prepared.calls.length == 2, "expected approval and mint");
        require(prepared.calls[0].target == adapter.USDC(), "wrong approval target");
        require(prepared.calls[1].target == adapter.M_USDC(), "wrong mint target");
        require(prepared.validUntil == 0, "unexpected expiry");
    }

    function testExecutesSupplyAndObservesPositionOnFork() external {
        if (!_forkAvailable()) return;

        address account = address(1);
        uint256 amount = 1_000_000;
        uint256 balanceBefore = IMoonwellErc20(adapter.USDC()).balanceOf(account);
        MoonwellUsdcPosition memory beforePosition =
            abi.decode(adapter.query(adapter.USDC_POSITION_QUERY(), abi.encode(account)), (MoonwellUsdcPosition));
        MoonwellSupplyParameters memory parameters =
            MoonwellSupplyParameters({amount: amount, enableAsCollateral: true});
        PreparedAction memory prepared = adapter.prepare(adapter.SUPPLY_USDC_ACTION(), account, abi.encode(parameters));
        require(prepared.calls.length == 3, "expected approval, enter, and mint");

        vm.startPrank(account);
        for (uint256 i = 0; i < prepared.calls.length; i++) {
            Call memory preparedCall = prepared.calls[i];
            (bool success, bytes memory returnData) =
                preparedCall.target.call{value: preparedCall.value}(preparedCall.data);
            require(success, "prepared call reverted");
            if (preparedCall.target == adapter.USDC()) {
                require(abi.decode(returnData, (bool)), "approval failed");
            } else if (preparedCall.target == adapter.COMPTROLLER()) {
                uint256[] memory errorCodes = abi.decode(returnData, (uint256[]));
                require(errorCodes.length == 1 && errorCodes[0] == 0, "enter market failed");
            } else {
                require(abi.decode(returnData, (uint256)) == 0, "mint failed");
            }
        }
        vm.stopPrank();

        MoonwellUsdcPosition memory afterPosition =
            abi.decode(adapter.query(adapter.USDC_POSITION_QUERY(), abi.encode(account)), (MoonwellUsdcPosition));
        require(IMoonwellErc20(adapter.USDC()).balanceOf(account) == balanceBefore - amount, "USDC not supplied");
        require(afterPosition.mTokenBalance > beforePosition.mTokenBalance, "mToken not received");
        require(afterPosition.suppliedUnderlying > beforePosition.suppliedUnderlying, "position unchanged");
        require(afterPosition.collateralEnabled, "collateral not enabled");
    }

    function _forkAvailable() private view returns (bool) {
        return
            adapter.USDC().code.length != 0 && adapter.M_USDC().code.length != 0
                && adapter.COMPTROLLER().code.length != 0;
    }
}

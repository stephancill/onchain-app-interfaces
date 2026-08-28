// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, PreparedAction} from "../contracts/IApplicationActions.sol";
import {
    AerodromeApplicationAdapter,
    AerodromeLpPosition,
    AerodromePoolState,
    AerodromeRoute,
    AerodromeSwapParameters,
    AerodromeSwapQuote,
    IAerodromeRouter,
    IERC20Allowance
} from "../contracts/adapters/AerodromeApplicationAdapter.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

interface IWeth is IERC20Balance {
    function deposit() external payable;
}

contract AerodromeApplicationAdapterTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    AerodromeApplicationAdapter internal adapter = new AerodromeApplicationAdapter();

    function testDiscoversQueriesAndActions() external view {
        bytes32[] memory queryIds = adapter.queries();
        bytes32[] memory actionIds = adapter.actions();
        require(queryIds.length == 3, "wrong query count");
        require(actionIds.length == 1, "wrong action count");
        require(queryIds[0] == adapter.POOL_STATE_QUERY(), "missing pool query");
        require(queryIds[1] == adapter.LP_POSITION_QUERY(), "missing position query");
        require(queryIds[2] == adapter.SWAP_QUOTE_QUERY(), "missing quote query");
        require(actionIds[0] == adapter.SWAP_ACTION(), "missing swap action");
    }

    function testRejectsUnsupportedSwapPair() external view {
        AerodromeSwapParameters memory parameters = AerodromeSwapParameters({
            tokenIn: adapter.WETH(),
            tokenOut: address(0xdead),
            amountIn: 1 ether,
            maxSlippageBps: 50,
            deadline: block.timestamp + 300
        });
        (bool success,) = address(adapter)
            .staticcall(
                abi.encodeCall(adapter.prepare, (adapter.SWAP_ACTION(), address(0xbeef), abi.encode(parameters)))
            );
        require(!success, "unsupported pair should fail");
    }

    function testReadsLivePoolState() external view {
        if (!_forkAvailable()) return;

        AerodromePoolState memory state =
            abi.decode(adapter.query(adapter.POOL_STATE_QUERY(), bytes("")), (AerodromePoolState));
        require(state.pool == adapter.POOL(), "wrong pool");
        require(state.token0 == adapter.WETH(), "wrong token0");
        require(state.token1 == adapter.USDC(), "wrong token1");
        require(state.reserve0 > 0 && state.reserve1 > 0, "empty reserves");
        require(state.totalSupply > 0, "empty supply");
        // forge-lint: disable-next-line(block-timestamp)
        require(state.observedAt == block.timestamp, "wrong observation time");
    }

    function testAggregatesLiveLpPosition() external view {
        if (!_forkAvailable()) return;

        address account = address(1);
        AerodromePoolState memory state =
            abi.decode(adapter.query(adapter.POOL_STATE_QUERY(), bytes("")), (AerodromePoolState));
        AerodromeLpPosition memory position =
            abi.decode(adapter.query(adapter.LP_POSITION_QUERY(), abi.encode(account)), (AerodromeLpPosition));

        require(position.account == account, "wrong account");
        require(position.liquidity > 0, "expected minimum liquidity");
        require(position.amount0 == state.reserve0 * position.liquidity / state.totalSupply, "wrong token0 amount");
        require(position.amount1 == state.reserve1 * position.liquidity / state.totalSupply, "wrong token1 amount");
    }

    function testQuotesLiveDirectSwap() external view {
        if (!_forkAvailable()) return;

        uint256 amountIn = 0.001 ether;
        AerodromeSwapQuote memory quote = abi.decode(
            adapter.query(adapter.SWAP_QUOTE_QUERY(), abi.encode(adapter.WETH(), adapter.USDC(), amountIn)),
            (AerodromeSwapQuote)
        );
        require(quote.tokenIn == adapter.WETH(), "wrong input token");
        require(quote.tokenOut == adapter.USDC(), "wrong output token");
        require(quote.amountIn == amountIn, "wrong input amount");
        require(quote.amountOut > 0, "empty quote");
        // forge-lint: disable-next-line(block-timestamp)
        require(quote.observedAt == block.timestamp, "wrong observation time");
    }

    function testPreparesLiveApprovalAndSwap() external view {
        if (!_forkAvailable()) return;

        address account = address(0xbeef);
        uint256 amountIn = 0.001 ether;
        uint256 slippageBps = 50;
        uint256 deadline = block.timestamp + 300;
        AerodromeSwapParameters memory parameters = AerodromeSwapParameters({
            tokenIn: adapter.WETH(),
            tokenOut: adapter.USDC(),
            amountIn: amountIn,
            maxSlippageBps: slippageBps,
            deadline: deadline
        });
        PreparedAction memory prepared = adapter.prepare(adapter.SWAP_ACTION(), account, abi.encode(parameters));

        require(prepared.calls.length == 2, "expected approval and swap");
        require(prepared.validUntil == deadline, "wrong validity");
        require(prepared.calls[0].target == adapter.WETH(), "wrong approval target");
        require(prepared.calls[0].value == 0, "approval has value");
        require(
            keccak256(prepared.calls[0].data)
                == keccak256(abi.encodeCall(IERC20Allowance.approve, (adapter.ROUTER(), amountIn))),
            "wrong approval calldata"
        );

        AerodromeSwapQuote memory quote = abi.decode(
            adapter.query(adapter.SWAP_QUOTE_QUERY(), abi.encode(adapter.WETH(), adapter.USDC(), amountIn)),
            (AerodromeSwapQuote)
        );
        uint256 amountOutMin = quote.amountOut * (10_000 - slippageBps) / 10_000;
        AerodromeRoute[] memory routes = new AerodromeRoute[](1);
        routes[0] =
            AerodromeRoute({from: adapter.WETH(), to: adapter.USDC(), stable: false, factory: adapter.POOL_FACTORY()});
        Call memory swapCall = prepared.calls[1];
        require(swapCall.target == adapter.ROUTER(), "wrong swap target");
        require(swapCall.value == 0, "swap has value");
        require(
            keccak256(swapCall.data)
                == keccak256(
                    abi.encodeCall(
                        IAerodromeRouter.swapExactTokensForTokens, (amountIn, amountOutMin, routes, account, deadline)
                    )
                ),
            "wrong swap calldata"
        );
    }

    function testExecutesPreparedSwapBundleOnFork() external {
        if (!_forkAvailable()) return;

        address account = address(0xa11ce);
        uint256 amountIn = 0.001 ether;
        AerodromePoolState memory beforeState =
            abi.decode(adapter.query(adapter.POOL_STATE_QUERY(), bytes("")), (AerodromePoolState));
        vm.deal(account, amountIn);
        vm.startPrank(account);
        IWeth(adapter.WETH()).deposit{value: amountIn}();
        vm.stopPrank();

        AerodromeSwapParameters memory parameters = AerodromeSwapParameters({
            tokenIn: adapter.WETH(),
            tokenOut: adapter.USDC(),
            amountIn: amountIn,
            maxSlippageBps: 100,
            deadline: block.timestamp + 300
        });
        PreparedAction memory prepared = adapter.prepare(adapter.SWAP_ACTION(), account, abi.encode(parameters));

        vm.startPrank(account);
        for (uint256 i = 0; i < prepared.calls.length; i++) {
            Call memory preparedCall = prepared.calls[i];
            (bool success,) = preparedCall.target.call{value: preparedCall.value}(preparedCall.data);
            require(success, "prepared call failed");
        }
        vm.stopPrank();

        AerodromePoolState memory afterState =
            abi.decode(adapter.query(adapter.POOL_STATE_QUERY(), bytes("")), (AerodromePoolState));
        require(IERC20Balance(adapter.WETH()).balanceOf(account) == 0, "WETH not spent");
        require(IERC20Balance(adapter.USDC()).balanceOf(account) > 0, "USDC not received");
        require(afterState.reserve0 > beforeState.reserve0, "WETH reserve did not increase");
        require(afterState.reserve1 < beforeState.reserve1, "USDC reserve did not decrease");
    }

    function testOmitsApprovalWhenAllowanceIsSufficient() external {
        if (!_forkAvailable()) return;

        address account = address(0xb0b);
        uint256 amountIn = 0.001 ether;
        vm.startPrank(account);
        IERC20Allowance(adapter.WETH()).approve(adapter.ROUTER(), amountIn);
        vm.stopPrank();

        AerodromeSwapParameters memory parameters = AerodromeSwapParameters({
            tokenIn: adapter.WETH(),
            tokenOut: adapter.USDC(),
            amountIn: amountIn,
            maxSlippageBps: 50,
            deadline: block.timestamp + 300
        });
        PreparedAction memory prepared = adapter.prepare(adapter.SWAP_ACTION(), account, abi.encode(parameters));

        require(prepared.calls.length == 1, "approval should be omitted");
        require(prepared.calls[0].target == adapter.ROUTER(), "expected swap call");
    }

    function _forkAvailable() private view returns (bool) {
        return adapter.POOL().code.length != 0 && adapter.ROUTER().code.length != 0;
    }
}

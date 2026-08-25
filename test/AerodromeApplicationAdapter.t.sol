// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, PreparedAction} from "../contracts/IApplicationActions.sol";
import {
    AerodromeApplicationAdapter,
    AerodromeLpPosition,
    AerodromePoolResult,
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
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant USDBC = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
    address internal constant WETH_USDC_POOL = 0xcDAC0d6c6C59727a65F871236188350531885C43;
    address internal constant USDC_USDBC_POOL = 0x27a8Afa3Bd49406e48a074350fB7b2020c43B2bD;
    AerodromeApplicationAdapter internal adapter = new AerodromeApplicationAdapter();

    function testDiscoversQueriesAndActions() external view {
        bytes32[] memory queryIds = adapter.queries();
        bytes32[] memory actionIds = adapter.actions();
        require(queryIds.length == 4, "wrong query count");
        require(actionIds.length == 1, "wrong action count");
        require(queryIds[0] == adapter.POOL_STATE_QUERY(), "missing pool query");
        require(queryIds[1] == adapter.LP_POSITION_QUERY(), "missing position query");
        require(queryIds[2] == adapter.SWAP_QUOTE_QUERY(), "missing quote query");
        require(queryIds[3] == adapter.POOL_QUERY(), "missing pool search query");
        require(actionIds[0] == adapter.SWAP_ACTION(), "missing swap action");
    }

    function testFindsCanonicalPools() external view {
        if (!_forkAvailable()) return;

        AerodromePoolResult memory volatilePool =
            abi.decode(adapter.query(adapter.POOL_QUERY(), abi.encode(WETH, USDC, false)), (AerodromePoolResult));
        require(volatilePool.pool == WETH_USDC_POOL, "wrong volatile pool");
        require(!volatilePool.stable, "wrong volatile type");

        AerodromePoolResult memory stablePool =
            abi.decode(adapter.query(adapter.POOL_QUERY(), abi.encode(USDC, USDBC, true)), (AerodromePoolResult));
        require(stablePool.pool == USDC_USDBC_POOL, "wrong stable pool");
        require(stablePool.stable, "wrong stable type");
    }

    function testRejectsUnsupportedSwapPair() external view {
        AerodromeSwapParameters memory parameters = AerodromeSwapParameters({
            pool: WETH_USDC_POOL,
            tokenIn: WETH,
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

    function testRejectsNonAerodromePool() external view {
        (bool success,) = address(adapter)
            .staticcall(abi.encodeCall(adapter.query, (adapter.POOL_STATE_QUERY(), abi.encode(address(1)))));
        require(!success, "non-pool should fail");
    }

    function testReadsLivePoolState() external view {
        if (!_forkAvailable()) return;

        AerodromePoolState memory state =
            abi.decode(adapter.query(adapter.POOL_STATE_QUERY(), abi.encode(WETH_USDC_POOL)), (AerodromePoolState));
        require(state.pool == WETH_USDC_POOL, "wrong pool");
        require(state.token0 == WETH, "wrong token0");
        require(state.token1 == USDC, "wrong token1");
        require(!state.stable, "wrong pool type");
        require(state.reserve0 > 0 && state.reserve1 > 0, "empty reserves");
        require(state.totalSupply > 0, "empty supply");
        // forge-lint: disable-next-line(block-timestamp)
        require(state.observedAt == block.timestamp, "wrong observation time");
    }

    function testReadsLiveStablePoolState() external view {
        if (!_forkAvailable()) return;

        AerodromePoolState memory state =
            abi.decode(adapter.query(adapter.POOL_STATE_QUERY(), abi.encode(USDC_USDBC_POOL)), (AerodromePoolState));
        require(state.pool == USDC_USDBC_POOL, "wrong pool");
        require(state.stable, "expected stable pool");
        require(
            (state.token0 == USDC && state.token1 == USDBC) || (state.token0 == USDBC && state.token1 == USDC),
            "wrong stable pair"
        );
        require(state.reserve0 > 0 && state.reserve1 > 0, "empty stable reserves");
    }

    function testAggregatesLiveLpPosition() external view {
        if (!_forkAvailable()) return;

        address account = address(1);
        AerodromePoolState memory state =
            abi.decode(adapter.query(adapter.POOL_STATE_QUERY(), abi.encode(WETH_USDC_POOL)), (AerodromePoolState));
        AerodromeLpPosition memory position = abi.decode(
            adapter.query(adapter.LP_POSITION_QUERY(), abi.encode(WETH_USDC_POOL, account)), (AerodromeLpPosition)
        );

        require(position.pool == WETH_USDC_POOL, "wrong pool");
        require(position.account == account, "wrong account");
        require(position.token0 == state.token0 && position.token1 == state.token1, "wrong tokens");
        require(position.liquidity > 0, "expected minimum liquidity");
        require(position.amount0 == state.reserve0 * position.liquidity / state.totalSupply, "wrong token0 amount");
        require(position.amount1 == state.reserve1 * position.liquidity / state.totalSupply, "wrong token1 amount");
    }

    function testQuotesLiveDirectSwap() external view {
        if (!_forkAvailable()) return;

        uint256 amountIn = 0.001 ether;
        AerodromeSwapQuote memory quote = abi.decode(
            adapter.query(adapter.SWAP_QUOTE_QUERY(), abi.encode(WETH_USDC_POOL, WETH, USDC, amountIn)),
            (AerodromeSwapQuote)
        );
        require(quote.pool == WETH_USDC_POOL, "wrong pool");
        require(quote.tokenIn == WETH, "wrong input token");
        require(quote.tokenOut == USDC, "wrong output token");
        require(!quote.stable, "wrong pool type");
        require(quote.amountIn == amountIn, "wrong input amount");
        require(quote.amountOut > 0, "empty quote");
        // forge-lint: disable-next-line(block-timestamp)
        require(quote.observedAt == block.timestamp, "wrong observation time");
    }

    function testQuotesLiveStableSwap() external view {
        if (!_forkAvailable()) return;

        AerodromeSwapQuote memory quote = abi.decode(
            adapter.query(adapter.SWAP_QUOTE_QUERY(), abi.encode(USDC_USDBC_POOL, USDC, USDBC, 1_000_000)),
            (AerodromeSwapQuote)
        );
        require(quote.pool == USDC_USDBC_POOL, "wrong stable pool");
        require(quote.stable, "expected stable route");
        require(quote.amountOut > 0, "empty stable quote");
    }

    function testPreparesLiveApprovalAndSwap() external view {
        if (!_forkAvailable()) return;

        address account = address(0xbeef);
        uint256 amountIn = 0.001 ether;
        uint256 slippageBps = 50;
        uint256 deadline = block.timestamp + 300;
        AerodromeSwapParameters memory parameters = AerodromeSwapParameters({
            pool: WETH_USDC_POOL,
            tokenIn: WETH,
            tokenOut: USDC,
            amountIn: amountIn,
            maxSlippageBps: slippageBps,
            deadline: deadline
        });
        PreparedAction memory prepared = adapter.prepare(adapter.SWAP_ACTION(), account, abi.encode(parameters));

        require(prepared.calls.length == 2, "expected approval and swap");
        require(prepared.validUntil == deadline, "wrong validity");
        require(prepared.calls[0].target == WETH, "wrong approval target");
        require(prepared.calls[0].value == 0, "approval has value");
        require(
            keccak256(prepared.calls[0].data)
                == keccak256(abi.encodeCall(IERC20Allowance.approve, (adapter.ROUTER(), amountIn))),
            "wrong approval calldata"
        );

        AerodromeSwapQuote memory quote = abi.decode(
            adapter.query(adapter.SWAP_QUOTE_QUERY(), abi.encode(WETH_USDC_POOL, WETH, USDC, amountIn)),
            (AerodromeSwapQuote)
        );
        uint256 amountOutMin = quote.amountOut * (10_000 - slippageBps) / 10_000;
        AerodromeRoute[] memory routes = new AerodromeRoute[](1);
        routes[0] = AerodromeRoute({from: WETH, to: USDC, stable: false, factory: adapter.POOL_FACTORY()});
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
            abi.decode(adapter.query(adapter.POOL_STATE_QUERY(), abi.encode(WETH_USDC_POOL)), (AerodromePoolState));
        vm.deal(account, amountIn);
        vm.startPrank(account);
        IWeth(WETH).deposit{value: amountIn}();
        vm.stopPrank();

        AerodromeSwapParameters memory parameters = AerodromeSwapParameters({
            pool: WETH_USDC_POOL,
            tokenIn: WETH,
            tokenOut: USDC,
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
            abi.decode(adapter.query(adapter.POOL_STATE_QUERY(), abi.encode(WETH_USDC_POOL)), (AerodromePoolState));
        require(IERC20Balance(WETH).balanceOf(account) == 0, "WETH not spent");
        require(IERC20Balance(USDC).balanceOf(account) > 0, "USDC not received");
        require(afterState.reserve0 > beforeState.reserve0, "WETH reserve did not increase");
        require(afterState.reserve1 < beforeState.reserve1, "USDC reserve did not decrease");
    }

    function testOmitsApprovalWhenAllowanceIsSufficient() external {
        if (!_forkAvailable()) return;

        address account = address(0xb0b);
        uint256 amountIn = 0.001 ether;
        vm.startPrank(account);
        IERC20Allowance(WETH).approve(adapter.ROUTER(), amountIn);
        vm.stopPrank();

        AerodromeSwapParameters memory parameters = AerodromeSwapParameters({
            pool: WETH_USDC_POOL,
            tokenIn: WETH,
            tokenOut: USDC,
            amountIn: amountIn,
            maxSlippageBps: 50,
            deadline: block.timestamp + 300
        });
        PreparedAction memory prepared = adapter.prepare(adapter.SWAP_ACTION(), account, abi.encode(parameters));

        require(prepared.calls.length == 1, "approval should be omitted");
        require(prepared.calls[0].target == adapter.ROUTER(), "expected swap call");
    }

    function _forkAvailable() private view returns (bool) {
        return WETH_USDC_POOL.code.length != 0 && adapter.ROUTER().code.length != 0;
    }
}

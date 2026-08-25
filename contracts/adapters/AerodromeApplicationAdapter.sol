// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, IApplicationActions, PreparedAction} from "../IApplicationActions.sol";
import {IApplicationQueries} from "../IApplicationQueries.sol";

struct AerodromeRoute {
    address from;
    address to;
    bool stable;
    address factory;
}

struct AerodromePoolState {
    address pool;
    address token0;
    address token1;
    bool stable;
    uint256 reserve0;
    uint256 reserve1;
    uint256 totalSupply;
    uint256 observedAt;
}

struct AerodromePoolResult {
    address pool;
    address token0;
    address token1;
    bool stable;
    uint256 observedAt;
}

struct AerodromeLpPosition {
    address pool;
    address account;
    address token0;
    address token1;
    uint256 liquidity;
    uint256 amount0;
    uint256 amount1;
    uint256 observedAt;
}

struct AerodromeSwapQuote {
    address pool;
    address tokenIn;
    address tokenOut;
    bool stable;
    uint256 amountIn;
    uint256 amountOut;
    uint256 observedAt;
}

struct AerodromeSwapParameters {
    address pool;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 maxSlippageBps;
    uint256 deadline;
}

interface IAerodromePool {
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function stable() external view returns (bool);
    function factory() external view returns (address);
}

interface IAerodromePoolFactory {
    function isPool(address pool) external view returns (bool);
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address pool);
}

interface IAerodromeRouter {
    function getAmountsOut(uint256 amountIn, AerodromeRoute[] calldata routes)
        external
        view
        returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        AerodromeRoute[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IERC20Allowance {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Experimental fully onchain application adapter for canonical direct Aerodrome Base pools.
contract AerodromeApplicationAdapter is IApplicationQueries, IApplicationActions {
    bytes32 public constant POOL_QUERY = keccak256("aerodrome.pool");
    bytes32 public constant POOL_STATE_QUERY = keccak256("aerodrome.poolState");
    bytes32 public constant LP_POSITION_QUERY = keccak256("aerodrome.lpPosition");
    bytes32 public constant SWAP_QUOTE_QUERY = keccak256("aerodrome.swapQuote.exactInput");
    bytes32 public constant SWAP_ACTION = keccak256("aerodrome.swap.exactInput");

    address public constant POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address public constant ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;

    error UnknownQuery(bytes32 queryId);
    error UnknownAction(bytes32 actionId);
    error InvalidPool(address pool);
    error PoolNotFound(address tokenA, address tokenB, bool stable);
    error UnsupportedPair(address pool, address tokenIn, address tokenOut);
    error InvalidAmount();
    error InvalidSlippage(uint256 maxSlippageBps);
    error InvalidDeadline(uint256 deadline);
    error InvalidAccount();
    error InvalidQuote();

    function queries() external pure returns (bytes32[] memory queryIds) {
        queryIds = new bytes32[](4);
        queryIds[0] = POOL_STATE_QUERY;
        queryIds[1] = LP_POSITION_QUERY;
        queryIds[2] = SWAP_QUOTE_QUERY;
        queryIds[3] = POOL_QUERY;
    }

    function queryDescriptor(bytes32 queryId) external pure returns (bytes memory descriptor) {
        if (queryId == POOL_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"aerodrome.pool","inputs":{"encoding":"abi","fields":[{"name":"tokenA","abiType":"address","semanticType":"erc20"},{"name":"tokenB","abiType":"address","semanticType":"erc20"},{"name":"stable","abiType":"bool"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"pool","abiType":"address","semanticType":"contract"},{"name":"token0","abiType":"address","semanticType":"erc20"},{"name":"token1","abiType":"address","semanticType":"erc20"},{"name":"stable","abiType":"bool"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"onchain"}}'
            );
        }
        if (queryId == POOL_STATE_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"aerodrome.poolState","inputs":{"encoding":"abi","fields":[{"name":"pool","abiType":"address","semanticType":"contract"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"pool","abiType":"address","semanticType":"contract"},{"name":"token0","abiType":"address","semanticType":"erc20"},{"name":"token1","abiType":"address","semanticType":"erc20"},{"name":"stable","abiType":"bool"},{"name":"reserve0","abiType":"uint256","semanticType":"tokenAmount","assetField":"result.token0"},{"name":"reserve1","abiType":"uint256","semanticType":"tokenAmount","assetField":"result.token1"},{"name":"totalSupply","abiType":"uint256","semanticType":"lpTokenAmount"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"onchain"}}'
            );
        }
        if (queryId == LP_POSITION_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"aerodrome.lpPosition","inputs":{"encoding":"abi","fields":[{"name":"pool","abiType":"address","semanticType":"contract"},{"name":"account","abiType":"address","semanticType":"account"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"pool","abiType":"address","semanticType":"contract"},{"name":"account","abiType":"address","semanticType":"account"},{"name":"token0","abiType":"address","semanticType":"erc20"},{"name":"token1","abiType":"address","semanticType":"erc20"},{"name":"liquidity","abiType":"uint256","semanticType":"lpTokenAmount"},{"name":"amount0","abiType":"uint256","semanticType":"tokenAmount","assetField":"result.token0"},{"name":"amount1","abiType":"uint256","semanticType":"tokenAmount","assetField":"result.token1"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"onchain"}}'
            );
        }
        if (queryId == SWAP_QUOTE_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"aerodrome.swapQuote.exactInput","inputs":{"encoding":"abi","fields":[{"name":"pool","abiType":"address","semanticType":"contract"},{"name":"tokenIn","abiType":"address","semanticType":"erc20"},{"name":"tokenOut","abiType":"address","semanticType":"erc20"},{"name":"amountIn","abiType":"uint256","semanticType":"tokenAmount","assetField":"tokenIn","minimum":"1"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"pool","abiType":"address","semanticType":"contract"},{"name":"tokenIn","abiType":"address","semanticType":"erc20"},{"name":"tokenOut","abiType":"address","semanticType":"erc20"},{"name":"stable","abiType":"bool"},{"name":"amountIn","abiType":"uint256","semanticType":"tokenAmount","assetField":"result.tokenIn"},{"name":"amountOut","abiType":"uint256","semanticType":"tokenAmount","assetField":"result.tokenOut"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"onchain"}}'
            );
        }
        revert UnknownQuery(queryId);
    }

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory result) {
        if (queryId == POOL_QUERY) {
            (address tokenA, address tokenB, bool stable) = abi.decode(parameters, (address, address, bool));
            return abi.encode(_pool(tokenA, tokenB, stable));
        }
        if (queryId == POOL_STATE_QUERY) {
            address pool = abi.decode(parameters, (address));
            return abi.encode(_poolState(pool));
        }
        if (queryId == LP_POSITION_QUERY) {
            (address pool, address account) = abi.decode(parameters, (address, address));
            if (account == address(0)) revert InvalidAccount();
            return abi.encode(_lpPosition(pool, account));
        }
        if (queryId == SWAP_QUOTE_QUERY) {
            (address pool, address tokenIn, address tokenOut, uint256 amountIn) =
                abi.decode(parameters, (address, address, address, uint256));
            return abi.encode(_swapQuote(pool, tokenIn, tokenOut, amountIn));
        }
        revert UnknownQuery(queryId);
    }

    function actions() external pure returns (bytes32[] memory actionIds) {
        actionIds = new bytes32[](1);
        actionIds[0] = SWAP_ACTION;
    }

    function actionDescriptor(bytes32 actionId) external pure returns (bytes memory descriptor) {
        if (actionId == SWAP_ACTION) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"aerodrome.swap.exactInput","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"pool","abiType":"address","semanticType":"contract"},{"name":"tokenIn","abiType":"address","semanticType":"erc20"},{"name":"tokenOut","abiType":"address","semanticType":"erc20"},{"name":"amountIn","abiType":"uint256","semanticType":"tokenAmount","assetField":"parameters.tokenIn","minimum":"1"},{"name":"maxSlippageBps","abiType":"uint256","semanticType":"basisPoints","minimum":"0","maximum":"1000"},{"name":"deadline","abiType":"uint256","semanticType":"timestamp"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","assetField":"parameters.tokenIn","amountField":"parameters.amountIn"},{"type":"increase","assetField":"parameters.tokenOut"}],"execution":{"atomicity":"atomic-required"},"provenance":{"type":"onchain"}}'
            );
        }
        revert UnknownAction(actionId);
    }

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory preparedAction)
    {
        if (actionId != SWAP_ACTION) revert UnknownAction(actionId);
        if (account == address(0)) revert InvalidAccount();

        AerodromeSwapParameters memory swap = abi.decode(parameters, (AerodromeSwapParameters));
        bool stable = _validatePair(swap.pool, swap.tokenIn, swap.tokenOut);
        if (swap.amountIn == 0) revert InvalidAmount();
        if (swap.maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert InvalidSlippage(swap.maxSlippageBps);
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (swap.deadline <= block.timestamp) revert InvalidDeadline(swap.deadline);

        preparedAction = PreparedAction({calls: _swapCalls(account, swap, stable), validUntil: swap.deadline});
    }

    function _swapCalls(address account, AerodromeSwapParameters memory swap, bool stable)
        private
        view
        returns (Call[] memory calls)
    {
        uint256 amountOutMin = _quote(swap.pool, swap.tokenIn, swap.tokenOut, swap.amountIn, stable)
            * (10_000 - swap.maxSlippageBps) / 10_000;
        bool approvalRequired = IERC20Allowance(swap.tokenIn).allowance(account, ROUTER) < swap.amountIn;
        calls = new Call[](approvalRequired ? 2 : 1);
        uint256 swapIndex;
        if (approvalRequired) {
            calls[0] = Call({
                target: swap.tokenIn, value: 0, data: abi.encodeCall(IERC20Allowance.approve, (ROUTER, swap.amountIn))
            });
            swapIndex = 1;
        }
        calls[swapIndex] = Call({
            target: ROUTER,
            value: 0,
            data: abi.encodeCall(
                IAerodromeRouter.swapExactTokensForTokens,
                (swap.amountIn, amountOutMin, _route(swap.tokenIn, swap.tokenOut, stable), account, swap.deadline)
            )
        });
    }

    function _poolState(address pool) private view returns (AerodromePoolState memory state) {
        (address token0, address token1, bool stable) = _validatePool(pool);
        (uint256 reserve0, uint256 reserve1,) = IAerodromePool(pool).getReserves();
        state = AerodromePoolState({
            pool: pool,
            token0: token0,
            token1: token1,
            stable: stable,
            reserve0: reserve0,
            reserve1: reserve1,
            totalSupply: IAerodromePool(pool).totalSupply(),
            observedAt: block.timestamp
        });
    }

    function _pool(address tokenA, address tokenB, bool stable)
        private
        view
        returns (AerodromePoolResult memory result)
    {
        address pool = IAerodromePoolFactory(POOL_FACTORY).getPool(tokenA, tokenB, stable);
        if (pool == address(0)) revert PoolNotFound(tokenA, tokenB, stable);
        (address token0, address token1, bool poolStable) = _validatePool(pool);
        result = AerodromePoolResult({
            pool: pool, token0: token0, token1: token1, stable: poolStable, observedAt: block.timestamp
        });
    }

    function _lpPosition(address pool, address account) private view returns (AerodromeLpPosition memory position) {
        AerodromePoolState memory state = _poolState(pool);
        uint256 liquidity = IAerodromePool(pool).balanceOf(account);
        uint256 amount0;
        uint256 amount1;
        if (state.totalSupply != 0) {
            amount0 = state.reserve0 * liquidity / state.totalSupply;
            amount1 = state.reserve1 * liquidity / state.totalSupply;
        }
        position = AerodromeLpPosition({
            pool: pool,
            account: account,
            token0: state.token0,
            token1: state.token1,
            liquidity: liquidity,
            amount0: amount0,
            amount1: amount1,
            observedAt: block.timestamp
        });
    }

    function _swapQuote(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        private
        view
        returns (AerodromeSwapQuote memory quote)
    {
        bool stable = _validatePair(pool, tokenIn, tokenOut);
        quote = AerodromeSwapQuote({
            pool: pool,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            stable: stable,
            amountIn: amountIn,
            amountOut: _quote(pool, tokenIn, tokenOut, amountIn, stable),
            observedAt: block.timestamp
        });
    }

    function _quote(address pool, address tokenIn, address tokenOut, uint256 amountIn, bool stable)
        private
        view
        returns (uint256 amountOut)
    {
        if (IAerodromePoolFactory(POOL_FACTORY).getPool(tokenIn, tokenOut, stable) != pool) {
            revert InvalidPool(pool);
        }
        if (amountIn == 0) revert InvalidAmount();
        uint256[] memory amounts = IAerodromeRouter(ROUTER).getAmountsOut(amountIn, _route(tokenIn, tokenOut, stable));
        if (amounts.length != 2 || amounts[1] == 0) revert InvalidQuote();
        return amounts[1];
    }

    function _route(address tokenIn, address tokenOut, bool stable)
        private
        pure
        returns (AerodromeRoute[] memory routes)
    {
        routes = new AerodromeRoute[](1);
        routes[0] = AerodromeRoute({from: tokenIn, to: tokenOut, stable: stable, factory: POOL_FACTORY});
    }

    function _validatePool(address pool) private view returns (address token0, address token1, bool stable) {
        if (pool == address(0) || !IAerodromePoolFactory(POOL_FACTORY).isPool(pool)) revert InvalidPool(pool);
        IAerodromePool candidate = IAerodromePool(pool);
        if (candidate.factory() != POOL_FACTORY) revert InvalidPool(pool);
        token0 = candidate.token0();
        token1 = candidate.token1();
        stable = candidate.stable();
        if (
            token0 == address(0) || token1 == address(0) || token0 == token1
                || IAerodromePoolFactory(POOL_FACTORY).getPool(token0, token1, stable) != pool
        ) revert InvalidPool(pool);
    }

    function _validatePair(address pool, address tokenIn, address tokenOut) private view returns (bool stable) {
        (address token0, address token1, bool poolStable) = _validatePool(pool);
        if (!((tokenIn == token0 && tokenOut == token1) || (tokenIn == token1 && tokenOut == token0))) {
            revert UnsupportedPair(pool, tokenIn, tokenOut);
        }
        return poolStable;
    }
}

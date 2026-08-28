# Aerodrome Application Adapter

## Status

Experimental reference adapter for the Base mainnet Aerodrome volatile WETH/USDC pool.

The implementation is `contracts/adapters/AerodromeApplicationAdapter.sol`.

## Purpose

This adapter is the fully onchain control for the Application Interface prototype. It demonstrates semantic queries and action preparation using only current EVM state. It never invokes External Request.

It intentionally does not implement best-route discovery. Route graph construction remains an offchain concern in tools such as the Aerodrome Sugar SDK. The adapter supports one explicit direct pool so its behavior remains deterministic and fully onchain.

## Base Contracts

| Component | Address |
| --- | --- |
| WETH | `0x4200000000000000000000000000000000000006` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Volatile pool | `0xcDAC0d6c6C59727a65F871236188350531885C43` |
| Pool factory | `0x420DD381b31aEf6683db6B902084cB0FFECe40Da` |
| Router | `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` |

## Queries

### `aerodrome.poolState`

- ID: `keccak256("aerodrome.poolState")`
- Parameters: empty bytes
- Result: `abi.encode(AerodromePoolState)`

Returns token addresses, raw reserves, LP total supply, and observation timestamp.

### `aerodrome.lpPosition`

- ID: `keccak256("aerodrome.lpPosition")`
- Parameters: `abi.encode(address account)`
- Result: `abi.encode(AerodromeLpPosition)`

Returns the account's LP balance and its pro-rata share of current pool reserves. Amounts use raw token units and integer division rounds down.

### `aerodrome.swapQuote.exactInput`

- ID: `keccak256("aerodrome.swapQuote.exactInput")`
- Parameters: `abi.encode(address tokenIn, address tokenOut, uint256 amountIn)`
- Result: `abi.encode(AerodromeSwapQuote)`

Calls the live Aerodrome Router for one volatile route. Only WETH to USDC and USDC to WETH are accepted.

## Action

### `aerodrome.swap.exactInput`

- ID: `keccak256("aerodrome.swap.exactInput")`
- Parameters: `abi.encode(AerodromeSwapParameters)`

`AerodromeSwapParameters` contains:

- `tokenIn` and `tokenOut`;
- exact raw `amountIn`;
- `maxSlippageBps`, capped at 1,000 bps;
- an absolute Unix `deadline` later than the current block timestamp.

Preparation reads the live quote and account allowance. It returns:

- an exact ERC-20 approval when allowance is insufficient;
- an Aerodrome `swapExactTokensForTokens` call;
- `validUntil` equal to the router deadline.

The adapter supports wrapped WETH only. Native ETH wrapping is deliberately outside this first control.

## Validation

The Base fork suite verifies:

- query and action discovery;
- live pool-state and LP-position aggregation;
- live quotes in the supported pool;
- exact approval and router calldata;
- omission of the approval call when the account allowance is sufficient;
- execution of the returned call bundle by a funded account;
- a query, prepare, execute, query loop in which reserves change as expected.

Run it with:

```sh
bun run test:fork:aerodrome
```

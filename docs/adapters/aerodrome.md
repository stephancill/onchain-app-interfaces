# Aerodrome Application Adapter

## Status

Experimental reference adapter for canonical direct Aerodrome pools on Base mainnet.

The implementation is `contracts/adapters/AerodromeApplicationAdapter.sol`.

## Deployment

The generalized Base mainnet deployment is verified at [`0x31cB53007f5fDECEAa84d43ad4E387A081E13f7b`](https://basescan.org/address/0x31cB53007f5fDECEAa84d43ad4E387A081E13f7b). It was deployed in transaction [`0xbd94cc19a553da57573858de6bf12465fb9f40357178ab0634682bea3203208b`](https://basescan.org/tx/0xbd94cc19a553da57573858de6bf12465fb9f40357178ab0634682bea3203208b).

The previous WETH/USDC-only deployment remains available at `0x6Be0EeB08795EE4fca64FC643Dfe2e77227EFD93` but does not expose the generalized parameter ABI or pool search.

## Purpose

This adapter is the fully onchain control for the Application Interface prototype. It demonstrates semantic queries and action preparation using only current EVM state. It never invokes External Request.

It intentionally does not implement best-route discovery. Route graph construction remains an offchain concern in tools such as the Aerodrome Sugar SDK. Each request selects one explicit pool, so behavior remains deterministic and fully onchain.

Every selected pool must be registered by the canonical Base PoolFactory. The adapter reads its tokens and stable or volatile classification onchain, verifies that `getPool(token0, token1, stable)` resolves back to the supplied address, and never accepts a caller-provided router or factory.

## Base Contracts

| Component | Address |
| --- | --- |
| Pool factory | `0x420DD381b31aEf6683db6B902084cB0FFECe40Da` |
| Router | `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` |

The tests and web console use the volatile WETH/USDC pool at `0xcDAC0d6c6C59727a65F871236188350531885C43` as one example, not as an adapter restriction.

## Queries

### `aerodrome.pool`

- ID: `keccak256("aerodrome.pool")`
- Parameters: `abi.encode(address tokenA, address tokenB, bool stable)`
- Result: `abi.encode(AerodromePoolResult)`

Looks up the canonical pool in the Base PoolFactory, rejects missing pools, validates factory membership, and returns the pool contract address with canonical token ordering and pool type.

### `aerodrome.poolState`

- ID: `keccak256("aerodrome.poolState")`
- Parameters: `abi.encode(address pool)`
- Result: `abi.encode(AerodromePoolState)`

Returns the validated pool address, token addresses, stable flag, raw reserves, LP total supply, and observation timestamp.

### `aerodrome.lpPosition`

- ID: `keccak256("aerodrome.lpPosition")`
- Parameters: `abi.encode(address pool, address account)`
- Result: `abi.encode(AerodromeLpPosition)`

Returns the account's LP balance, the pool's token addresses, and its pro-rata share of current pool reserves. Amounts use raw token units and integer division rounds down.

### `aerodrome.swapQuote.exactInput`

- ID: `keccak256("aerodrome.swapQuote.exactInput")`
- Parameters: `abi.encode(address pool, address tokenIn, address tokenOut, uint256 amountIn)`
- Result: `abi.encode(AerodromeSwapQuote)`

Calls the live Aerodrome Router for one direct route. The token pair and stable flag must match the selected canonical pool.

## Action

### `aerodrome.swap.exactInput`

- ID: `keccak256("aerodrome.swap.exactInput")`
- Parameters: `abi.encode(AerodromeSwapParameters)`

`AerodromeSwapParameters` contains:

- the canonical `pool` address;
- `tokenIn` and `tokenOut`;
- exact raw `amountIn`;
- `maxSlippageBps`, capped at 1,000 bps;
- an absolute Unix `deadline` later than the current block timestamp.

Preparation reads the live quote and account allowance. It returns:

- an exact ERC-20 approval when allowance is insufficient;
- an Aerodrome `swapExactTokensForTokens` call;
- `validUntil` equal to the router deadline.

The adapter supports ERC-20 pool assets. Native-token wrapping, best-route discovery, and multi-hop routes remain outside this control.

## Validation

The Base fork suite verifies:

- query and action discovery;
- canonical pool-address lookup by token pair and pool type;
- live pool-state and LP-position aggregation for caller-selected pools;
- volatile and stable direct-pool quotes;
- rejection of addresses outside the canonical factory;
- exact approval and router calldata;
- omission of the approval call when the account allowance is sufficient;
- execution of the returned call bundle by a funded account;
- a query, prepare, execute, query loop in which reserves change as expected.

Run it with:

```sh
bun run test:fork:aerodrome
```

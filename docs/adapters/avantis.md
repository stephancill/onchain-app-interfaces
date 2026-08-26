# Avantis Application Adapter

## Status

Experimental hybrid adapter for Avantis v2 perpetual state and direct-trader actions on Base.

The implementation is `contracts/adapters/AvantisApplicationAdapter.sol`.

## Deployment

The current generation uses declarative client-side JSON extraction for the positions query and is deployed separately from the earlier codec-generation deployment. Deployment addresses for the current contracts are recorded in `docs/implementation-notes.md` after each release.

The previous generation (positions normalization onchain) was verified at [`0x8B223f20899589BaA13d1a8d9971Dd0cDDc6356b`](https://basescan.org/address/0x8b223f20899589baa13d1a8d9971dd0cddc6356b) with codecs at `0xB2d66277B7258B709d6bC9b54ee34959b6FAD280`, `0x460a31b433DFBE899aC48141b3240EDA6Ac66Da0`, and `0xc5AE01b76468703B0c6023Ac7Db41583603c8C69`. It remains immutable but is superseded, as is the open-only deployment at `0x53c8B42bf72C286e453D56F74831E9DFb975b0d6`.

## Purpose

This adapter translates the Avantis capabilities documented by the Base MCP plugin into:

- an account-bound, typed current-state query using Avantis's public core API;
- open, close, pending-order, margin, and delegation actions using the Avantis tx-builder with strict calldata validation.

The adapter prepares direct trader-signed calls. It can set or remove delegates, but delegated execution of the trading actions is not exposed in this revision.

## Configuration

The constructor accepts separate core API and transaction-builder origins. Canonical values are:

```text
https://core.avantisfi.com
https://tx-builder.avantisfi.com
```

The adapter uses the live versioned Avantis v2 builder routes. The Base MCP document still contains some unversioned route examples, while the current OpenAPI publishes `/v2/trade/open`, `/v2/trade/close`, `/v2/limit/cancel`, `/v2/margin/update`, `/v2/limit/update`, and `/v2/delegate/*`.

## Architecture

The deployment consists of the adapter and two separately deployed codecs:

- `AvantisRequestCodec` validates semantic parameters and constructs builder URLs;
- `AvantisActionCodec` validates transaction envelopes and canonical calldata.

Positions responses are no longer normalized onchain. The callback validates transport-level properties (status, size) and returns the raw body; the descriptor declares a `json` output with extraction paths and `equalsInput` bindings, and the generic client performs typed extraction. This removes a gas-scaling wall: onchain JSON normalization measured ~650k gas per position even after optimization, making worst-case bounded responses impossible within public RPC `eth_call` limits.

The adapter pins each codec's runtime code hash in its bytecode and rejects an incorrect implementation at construction. It also creates a dedicated immutable descriptor helper so descriptor literals do not consume the adapter's EIP-170 runtime budget.

## Base Contracts

| Component | Address |
| --- | --- |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Trading | `0x44914408af82bC9983bbb330e3578E1105e11d4e` |
| TradingStorage | `0x8a311D7048c35985aa31C131B9A13e03a5f7422d` |

## Query

### `avantis.positions`

- Parameters: `abi.encode(address account)`
- Data source: `GET /user-data?trader={account}`
- Result: raw JSON body returned by the callback; the client extracts typed `positions` and `limitOrders` arrays according to the descriptor's JSON output fields.

Each position includes its trader, pair and trade indices, direction, collateral, leverage, open/TP/SL/liquidation prices, rollover fee, loss-protection tier, open time, and PnL/one-click flags. Each pending order includes its trader, pair and order indices, direction, creation block, collateral, position size, trigger price, leverage, TP/SL, slippage, execution fee, liquidation price, type, and one-click flag.

Values retain Avantis's canonical raw scaling: USDC amounts use `1e6`; prices, leverage, percentages, and slippage use `1e10`. Empty arrays mean the account has no current positions or pending orders. The descriptor bounds each array to 64 entries; the client rejects larger arrays. Every entry's trader is bound to the queried account via an `equalsInput` binding that the client enforces during extraction. Clients SHOULD stamp observation time locally when presenting results.

## Action

| Capability | Builder | Purpose |
| --- | --- | --- |
| `avantis.trade.open` | `GET /v2/trade/open` | Open market, zero-fee, limit, or stop-limit exposure |
| `avantis.trade.close` | `GET /v2/trade/close` | Close all or part of an open position |
| `avantis.limit.cancel` | `GET /v2/limit/cancel` | Cancel a pending limit or stop-limit order |
| `avantis.margin.update` | `GET /v2/margin/update` | Deposit or withdraw position collateral |
| `avantis.limit.update` | `GET /v2/limit/update` | Update a pending order's trigger, slippage, TP, and SL |
| `avantis.delegate.set` | `GET /v2/delegate/set` | Set a time-bounded trading delegate |
| `avantis.delegate.remove` | `GET /v2/delegate/remove` | Revoke a trading delegate |

Parameters use onchain units rather than human-decimal strings:

- `collateralUsdc`: USDC `1e6` units;
- `leverage`, `slippagePercent`, and all prices: Avantis `1e10` units;
- `executionFeeWei`: exact native-token value attached to the trade call.

Open and margin-deposit preparation verify the account's USDC balance. Their callbacks add an exact TradingStorage approval only when allowance is insufficient. Every callback rejects a builder response unless:

- `chainId` is Base and `from` is the requested account;
- `to` is the canonical Trading contract;
- `value` exactly matches the requested execution fee;
- calldata uses the exact selector for the requested capability;
- every caller-controlled field matches the semantic parameters;
- decoding and canonical re-encoding reproduce the complete calldata without trailing or alternative encodings.

Margin updates permit only the two supported Pyth sourcing modes and at most 16 KB of builder-supplied oracle update data. All prepared results are atomic-required and expire after one minute because pair availability, oracle data, server validation, and reusable position/order indices are time-sensitive.

Avantis v2 global TP/SL updates for an already open position are EIP-712 intents submitted to an HTTP endpoint rather than user EVM calls. The current action interface only returns `PreparedAction`, so the adapter does not misrepresent that flow as a transaction. `avantis.limit.update` covers direct TP/SL changes for pending orders.

## Trust Boundary

Position data is HTTPS-authenticated application data, not trustless onchain data. With the JSON output profile, structural and trader-binding validation happens in the generic client according to the descriptor rather than in contract code; the contract guarantees only response status and size bounds. The tx-builder is used as an encoder and pre-trade validator, but it cannot choose the signer, target, value, or trade semantics accepted by the callback. Pair listing, leverage envelopes, market hours, available open interest, position existence, and pending-order existence still rely on builder validation and can change before execution.

Avantis reuses numeric position and order slots. A reviewed slot can change before a prepared call executes, and the direct router calldata does not carry a position-instance timestamp. Clients must show the complete typed state, re-simulate immediately before authorization, and reject any changed target state even within the one-minute validity window.

Leveraged perpetual positions can be liquidated. Clients must surface direction, collateral, leverage, entry price, TP/SL, execution fee, and the liquidation risk before authorizing calls.

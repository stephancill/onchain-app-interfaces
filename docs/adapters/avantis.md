# Avantis Application Adapter

## Status

Experimental hybrid adapter for Avantis perpetual positions and trade opening on Base.

The implementation is `contracts/adapters/AvantisApplicationAdapter.sol`.

## Purpose

This adapter translates the Avantis capabilities documented by the Base MCP plugin into:

- an account-bound positions query using Avantis's public core API;
- an open-trade action using the Avantis tx-builder with strict calldata validation.

The adapter intentionally exposes one representative write rather than every management operation in the Avantis plugin. Close, cancel, margin, TP/SL, and delegation actions remain future work.

## Configuration

The constructor accepts separate core API and transaction-builder origins. Canonical values are:

```text
https://core.avantisfi.com
https://tx-builder.avantisfi.com
```

The linked Base MCP plugin documents `/trade/open`; the live Avantis OpenAPI document currently publishes the compatible builder as `/v2/trade/open`, which this adapter uses.

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
- Result: `abi.encode(AvantisPositionsResult)`

The result binds the raw public JSON body to the requested account and records HTTP status and observation time. Core API position values retain Avantis's raw scaling: USDC uses `1e6`, while price and leverage fields use `1e10`.

## Action

### `avantis.trade.open`

- Parameters: `abi.encode(AvantisOpenTradeParameters)`
- Builder: `GET /v2/trade/open`
- Supported order types: market, stop-limit, limit, and market-PnL

Parameters use onchain units rather than human-decimal strings:

- `collateralUsdc`: USDC `1e6` units;
- `leverage`, `slippagePercent`, and all prices: Avantis `1e10` units;
- `executionFeeWei`: exact native-token value attached to the trade call.

Preparation verifies the account's USDC balance. The callback rejects a builder response unless:

- `chainId` is Base and `from` is the requested account;
- `to` is the canonical Trading contract;
- `value` exactly matches the requested execution fee;
- calldata is the canonical `openTrade` encoding;
- every trade field, order type, and slippage value matches the semantic parameters.

The adapter adds an exact USDC approval to TradingStorage only when current allowance is insufficient. Approval and trade are declared atomic-required. Prepared results expire after five minutes because pair availability and server-side validation are time-sensitive.

## Trust Boundary

The positions body is HTTPS-authenticated application data, not trustless onchain data. The tx-builder is used as an encoder and pre-trade validator, but it cannot choose the signer, target, value, or trade semantics accepted by the callback. Pair listing, leverage envelopes, market hours, and available open interest still rely on builder validation and can change before execution.

Leveraged perpetual positions can be liquidated. Clients must surface direction, collateral, leverage, entry price, TP/SL, execution fee, and the liquidation risk before authorizing calls.

# Moonwell Application Adapter

## Status

Experimental hybrid reference adapter for listed Moonwell ERC-20 markets on Base.

The implementation is `contracts/adapters/MoonwellApplicationAdapter.sol`.

## Deployment

The generalized Base mainnet deployment is verified at [`0x805E521b5BD349B02380DC0C81bcd75bDb374FD2`](https://basescan.org/address/0x805E521b5BD349B02380DC0C81bcd75bDb374FD2). It was deployed with the canonical API origin in transaction [`0x5f4d02814aebe766e524cf3b84674faf8efd0e2b598ef35604e16ad7e38fa691`](https://basescan.org/tx/0x5f4d02814aebe766e524cf3b84674faf8efd0e2b598ef35604e16ad7e38fa691).

The previous USDC-specific deployment remains available at `0xFe58AD745170163A133895fAE16ea9D3021Dd281` but does not expose the generalized capability IDs, market parameters, or market search.

## Purpose

This adapter demonstrates one application interface combining:

- public external semantic queries for cross-market positions and health;
- a fully onchain semantic query for a selected listed market position;
- account-aware preparation of an ERC-20 supply action for a selected listed market.

Unlike a pass-through transaction API, the adapter constructs every action call from verified contract addresses and live onchain account state.

## Configuration

The constructor accepts the API origin. The canonical deployment value is:

```text
https://api.moonwell.fi
```

The configurable origin exists to support deterministic local continuation tests. Clients must establish adapter authenticity before trusting its configured origin.

## Base Contracts

| Component | Address |
| --- | --- |
| Comptroller | `0xfBb21d0380beE3312B33c4353c8936a0F13EF26C` |

The tests and web console use mUSDC at `0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22` as one example. Position tests also cover mMORPHO. These addresses are examples rather than adapter restrictions.

## Queries

### `moonwell.market`

- Parameters: `abi.encode(address underlying)`
- Data source: canonical Comptroller market registry and each listed market's `underlying()`
- Result: `abi.encode(MoonwellMarketResult)`

Returns the unique listed market contract for an underlying ERC-20. Missing and ambiguous matches revert rather than selecting an arbitrary market.

### `moonwell.positions`

- Parameters: `abi.encode(address account)`
- Data source: `GET /v1/positions/{account}?chain=base&active=true`
- Result: `abi.encode(MoonwellExternalQueryResult)`

### `moonwell.health`

- Parameters: `abi.encode(address account)`
- Data source: `GET /v1/health/{account}?chain=base`
- Result: `abi.encode(MoonwellExternalQueryResult)`

`MoonwellExternalQueryResult` binds the raw JSON body to its query ID and account and includes HTTP status and observation time. The v0 descriptor does not yet provide a machine-readable JSON schema, so the body remains API-shaped rather than normalized into Solidity fields.

### `moonwell.position`

- Parameters: `abi.encode(address account, address market)`
- Data source: selected market account snapshot and Comptroller membership
- Result: `abi.encode(MoonwellPosition)`

The adapter requires the market to use the canonical Comptroller and to be currently listed. It resolves `underlying()` from that validated market, computes supplied underlying from mToken balance and exchange rate, and returns current borrow balance and collateral status.

## Action

### `moonwell.supply`

- Parameters: `abi.encode(MoonwellSupplyParameters)`
- Fields: `market`, raw underlying `amount`, and `enableAsCollateral`

Preparation validates the market, derives its underlying token, verifies the account's underlying balance, and reads allowance and market-membership state. It conditionally returns:

1. Exact underlying-token approval to the selected market.
2. Comptroller `enterMarkets([market])` when collateral is requested and not already enabled.
3. Selected-market `mint(amount)`.

There is no quote-based expiry, so `validUntil` is zero.

Only listed markets exposing an ERC-20 `underlying()` are supported. A native market requiring payable minting would need a separate action shape rather than fallback behavior.

## Compound Return Codes

Moonwell inherits Compound v2 behavior in which `enterMarkets` and `mint` can complete at the EVM level while returning nonzero business-error codes. The fork test explicitly decodes and requires zero return codes.

An ordinary wallet executing `Call[]` may not enforce those return values. This is an unresolved limitation of the current prepared-action representation and a concrete input to the future validation/postcondition design.

The three calls also have partial-execution risk when submitted as independent EOA transactions: approval or collateral entry may succeed before mint fails. The current `PreparedAction` does not declare whether atomic execution is required.

## Trust Boundary

The client enforces HTTPS and origin policy before making an external request. The callback requires a nonempty 2xx response and binds it to the requested account and query ID, but does not cryptographically verify Moonwell API data. External query results must therefore be treated as HTTPS-authenticated application data, not trustless onchain facts.

## Validation

Local integration tests deploy the adapter to Anvil and complete health and positions queries through a local HTTPS fixture. Base fork tests resolve market addresses for multiple underlyings, verify live position aggregation across multiple listed markets, and execute a returned supply bundle unchanged while checking all Compound return codes and the resulting position.

```sh
bun run test:fork:moonwell
```

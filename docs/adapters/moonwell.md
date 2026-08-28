# Moonwell Application Adapter

## Status

Experimental hybrid reference adapter for Moonwell's current USDC market on Base.

The implementation is `contracts/adapters/MoonwellApplicationAdapter.sol`.

## Purpose

This adapter demonstrates one application interface combining:

- public external semantic queries for cross-market positions and health;
- a fully onchain semantic query for the current USDC market position;
- account-aware preparation of a Moonwell USDC supply action.

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
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Current mUSDC | `0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22` |
| Comptroller | `0xfBb21d0380beE3312B33c4353c8936a0F13EF26C` |

## Queries

### `moonwell.positions`

- Parameters: `abi.encode(address account)`
- Data source: `GET /v1/positions/{account}?chain=base&active=true`
- Result: `abi.encode(MoonwellExternalQueryResult)`

### `moonwell.health`

- Parameters: `abi.encode(address account)`
- Data source: `GET /v1/health/{account}?chain=base`
- Result: `abi.encode(MoonwellExternalQueryResult)`

`MoonwellExternalQueryResult` binds the raw JSON body to its query ID and account and includes HTTP status and observation time. The v0 descriptor does not yet provide a machine-readable JSON schema, so the body remains API-shaped rather than normalized into Solidity fields.

### `moonwell.position.usdc`

- Parameters: `abi.encode(address account)`
- Data source: current mUSDC account snapshot and Comptroller membership
- Result: `abi.encode(MoonwellUsdcPosition)`

The query computes supplied underlying USDC from mToken balance and exchange rate and returns current borrow balance and collateral status.

## Action

### `moonwell.supply.usdc`

- Parameters: `abi.encode(MoonwellSupplyParameters)`
- Fields: raw USDC `amount` and `enableAsCollateral`

Preparation verifies the account's USDC balance and reads allowance and market-membership state. It conditionally returns:

1. Exact USDC approval to mUSDC.
2. Comptroller `enterMarkets([mUSDC])` when collateral is requested and not already enabled.
3. mUSDC `mint(amount)`.

There is no quote-based expiry, so `validUntil` is zero.

## Compound Return Codes

Moonwell inherits Compound v2 behavior in which `enterMarkets` and `mint` can complete at the EVM level while returning nonzero business-error codes. The fork test explicitly decodes and requires zero return codes.

An ordinary wallet executing `Call[]` may not enforce those return values. This is an unresolved limitation of the current prepared-action representation and a concrete input to the future validation/postcondition design.

The three calls also have partial-execution risk when submitted as independent EOA transactions: approval or collateral entry may succeed before mint fails. The current `PreparedAction` does not declare whether atomic execution is required.

## Trust Boundary

The client enforces HTTPS and origin policy before making an external request. The callback requires a nonempty 2xx response and binds it to the requested account and query ID, but does not cryptographically verify Moonwell API data. External query results must therefore be treated as HTTPS-authenticated application data, not trustless onchain facts.

## Validation

Local integration tests deploy the adapter to Anvil and complete health and positions queries through a local HTTPS fixture. Base fork tests verify live position aggregation and execute the returned supply bundle unchanged while checking all Compound return codes and the resulting position.

```sh
bun run test:fork:moonwell
```

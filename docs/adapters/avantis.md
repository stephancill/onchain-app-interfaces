# Avantis Application Adapter

## Status

Experimental comprehensive adapter for Avantis v2 perpetual markets and position management on Base.

The implementation is `contracts/adapters/AvantisApplicationAdapter.sol`.

## Scope

The adapter exposes five queries and eight actions through one discoverable address. It follows the current Avantis v2 tx-builder OpenAPI rather than the older unversioned routes in Base MCP plugin v0.2.

Queries cover:

- service metadata, addresses, units, enums, and defaults;
- the complete market catalog;
- one market's leverage, liquidity, feed, and schedule configuration;
- an account's open positions and pending orders;
- the account's onchain USDC balance and TradingStorage allowance.

Actions cover:

- opening a market, market-PnL, limit, or stop-limit position;
- closing all or part of an open position;
- canceling or editing a pending limit order;
- increasing an open position;
- depositing or withdrawing position margin;
- setting or removing an expiring trading delegate.

Active-position TP/SL updates are not exposed. The live v2 service removed the direct transaction endpoint and now offers only EIP-712 intent construction. `PreparedAction` can return EVM calls but cannot request a typed-data signature, so pretending this operation is supported would produce an unusable action. Pending-order TP/SL remains editable through `avantis.limit.update`, and TP/SL can be set when opening a position.

## Configuration

The constructor accepts the Avantis tx-builder origin. The canonical value is:

```text
https://tx-builder.avantisfi.com
```

The constructor automatically deploys `AvantisApplicationDescriptors`, which stores the JSON descriptors outside the main adapter runtime. With the Foundry optimizer enabled, the adapter runtime is approximately 21.1 KB and remains below EIP-170.

## Base Contracts

| Component | Address |
| --- | --- |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Trading | `0x44914408af82bC9983bbb330e3578E1105e11d4e` |
| TradingStorage | `0x8a311D7048c35985aa31C131B9A13e03a5f7422d` |

## Queries

### `avantis.meta`

- Parameters: empty bytes
- Data source: `GET /v2/meta`
- Includes canonical addresses, enums, units, defaults, and EIP-712 domain metadata

### `avantis.markets`

- Parameters: empty bytes
- Data source: `GET /v2/pairs`
- Includes all listed pairs, leverage envelopes, minimum position sizes, open interest, liquidity caps, feed status, and market schedules

### `avantis.market`

- Parameters: `abi.encode(uint32 pairIndex)`
- Data source: `GET /v2/pairs/{pairIndex}`
- Provides one market's complete configuration

### `avantis.positions`

- Parameters: `abi.encode(address account)`
- Data source: `GET /v2/positions?trader={account}`
- Includes open trades and pending limit or stop-limit orders with the pair and slot indices required by management actions

### `avantis.account`

- Parameters: `abi.encode(address account)`
- Data source: Base contracts
- Returns USDC balance, allowance, canonical spender, and observation time

External query results bind the raw response state to the query ID, account where applicable, and hash of the exact encoded parameters. `avantis.meta`, `avantis.markets`, and `avantis.market` keep the raw JSON body plus a `rawBodyHash`. `avantis.positions` is projected client-side into named arrays of trade and order tuples before the callback, so the result is typed and account-bound rather than an opaque JSON blob. `avantis.account` returns the typed `AvantisAccountState` onchain result.

## Actions

| Action | Builder or source | Approval behavior |
| --- | --- | --- |
| `avantis.trade.open` | `GET /v2/trade/open` | Exact USDC collateral approval when required |
| `avantis.trade.close` | `GET /v2/trade/close` | None |
| `avantis.limit.cancel` | `GET /v2/limit/cancel` | None |
| `avantis.limit.update` | `GET /v2/limit/update` | None |
| `avantis.position.increase` | `GET /v2/position/increase` | Exact additional-collateral approval when required |
| `avantis.margin.update` | `GET /v2/margin/update` | Exact approval for deposits; none for withdrawals |
| `avantis.delegate.set` | Locally encoded `setDelegate` | None |
| `avantis.delegate.remove` | Locally encoded `removeDelegate` | None |

Open, close, increase, and limit-management callbacks require the builder response to match the locally constructed calldata byte-for-byte. They also require:

- Base chain ID;
- the requested account as signer;
- the canonical Trading target;
- the exact requested native-token value.

Every builder response is projected by the continuation client into a typed ABI body (`ResponseTransform` kind `JSON_ABI`) before these checks run, removing the previous onchain JSON parsing. The margin callback decodes the complete call in the same way, verifying pair, position index, deposit or withdrawal direction, collateral amount, price source, target, signer, and oracle fee, then checks canonical re-encoding. The Pyth update bytes inside the calldata remain externally supplied but are verified by the protocol onchain.

Approvals target TradingStorage and are added only when current allowance is insufficient. Approval plus action is declared atomic-required where collateral is pulled. Externally prepared results expire after five minutes because markets, liquidity, account state, and oracle data can change.

## Units

Semantic action parameters use canonical onchain integer units:

| Domain | Scale |
| --- | --- |
| USDC collateral and amounts | `1e6` |
| Prices, leverage, percentages, and slippage | `1e10` |
| Execution and oracle fees | wei |

The adapter converts these integers to exact human-decimal query values without floating-point arithmetic. Query JSON retains the units returned by Avantis v2; clients should use `/v2/meta` as the current source of truth.

## Management Flow

1. Query `avantis.markets` or `avantis.market` for listing, leverage, minimum position, liquidity, and market-hours constraints.
2. Query `avantis.account` for collateral balance and allowance.
3. Query `avantis.positions` before targeting an existing position or order; use its real pair and slot indices.
4. Prepare the selected action and review every returned call.
5. Execute approval and action atomically when both are returned.
6. Query `avantis.positions` again after settlement.

## Trust Boundary

Market and position bodies are HTTPS-authenticated application data, not trustless onchain data. The tx-builder performs pre-trade validation and supplies oracle update bytes, but it cannot alter any accepted signer, target, value, or decoded trade-management field. Pair listing, leverage envelopes, market hours, liquidity, and position existence can still change before execution.

Leveraged perpetual positions can be liquidated. Clients must surface direction, collateral, leverage, entry or trigger price, TP/SL, execution fee, liquidation price, and material margin changes before authorization.

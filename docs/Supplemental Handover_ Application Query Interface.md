# Supplemental Handover: Application Query Interface

**Status:** Proposed addition to existing technical handover
**Purpose:** Extend the current architecture to support machine-readable application-level read/query endpoints in addition to application actions.

This document should be incorporated into the existing handover alongside the **Application Action Resolver** and **External Request** specifications.

---

## 1. Summary of change

The current architecture standardizes:

```text
semantic user action
        ↓
IApplicationActions
        ↓
prepare(...)
        ↓
PreparedAction
        ↓
Call[]
```

This should be extended with a complementary read interface:

```text
semantic application query
        ↓
IApplicationQueries
        ↓
query(...)
        ↓
structured application data
```

Both actions and queries may depend on external data and may therefore invoke the same `ExternalRequest` continuation mechanism.

The resulting architecture is:

```text
                    Application Adapter
                           │
              ┌────────────┴────────────┐
              │                         │
           Queries                   Actions
              │                         │
         query(...)                prepare(...)
              │                         │
              └────────────┬────────────┘
                           │
                    may require
                    external data
                           │
                           ▼
                    ExternalRequest
                           │
                           ▼
                       callback
```

This creates a more complete machine interface for applications:

- **Queries describe what an application knows.**
- **Actions describe what a user can do.**

For AI agents in particular, both are necessary. An agent needs to observe application state before deciding which action to take.

---

# 2. Motivation

The original problem applies equally to reads and writes.

Smart contracts expose low-level state and functions, but application-level information often requires aggregation across:

- multiple contracts;
- indexed events;
- subgraphs;
- proprietary indexers;
- quote services;
- analytics services;
- user-specific APIs;
- permissioned APIs.

For example, an agent interacting with a lending application may need answers to:

```text
What positions does this user currently have?

What collateral is active?

What is their current health factor?

How much can they safely borrow?

What rewards are claimable?

Which markets are available?
```

The relevant information may technically be derivable from raw contract calls, but doing so may require detailed protocol-specific knowledge.

In other cases, the information may depend on indexed or offchain data that is not efficiently reconstructible from current contract state.

A generic agent should not need to independently reverse-engineer the application's frontend/indexer architecture to answer these questions.

The application should be able to expose semantic queries directly.

---

# 3. Core distinction

A query is an **application-level semantic read**, not a generic smart-contract getter.

This mirrors the existing distinction between protocol functions and application actions.

```text
contract function     != user action

storage getter        != application query
```

For example, a lending protocol may expose low-level functions such as:

```text
balanceOf(...)
getUserAccountData(...)
getReserveData(...)
rewardData(...)
```

while an application adapter exposes:

```text
lending.positions
lending.borrowCapacity
lending.claimableRewards
```

A single semantic query may internally combine:

```text
contract reads
+
event-indexed data
+
oracle data
+
external API data
```

before returning a useful application-level result.

---

# 4. Proposed interface

The current working interface is:

```solidity
interface IApplicationQueries {
    function queries()
        external
        view
        returns (bytes32[] memory queryIds);

    function queryDescriptor(
        bytes32 queryId
    )
        external
        view
        returns (bytes memory descriptor);

    function query(
        bytes32 queryId,
        bytes calldata parameters
    )
        external
        view
        returns (bytes memory result);
}
```

This is an experimental interface and should not yet be considered ABI-frozen.

---

# 5. `queries()`

```solidity
function queries()
    external
    view
    returns (bytes32[] memory queryIds);
```

This provides query discovery.

It answers:

> What application-level information can this adapter provide?

Example query IDs might correspond to:

```text
positions
portfolioSummary
claimableRewards
borrowCapacity
availableMarkets
currentQuote
protocolStats
transactionHistory
```

As with action IDs, the final naming or namespace convention is unresolved.

A likely direction is hashed names such as:

```solidity
keccak256("defi.lending.positions")
keccak256("defi.lending.borrowCapacity")
```

Canonical ecosystem-wide query naming should be deferred until implementation demonstrates that it is useful.

---

# 6. `queryDescriptor()`

```solidity
function queryDescriptor(
    bytes32 queryId
)
    external
    view
    returns (bytes memory descriptor);
```

A query descriptor needs to describe both:

1. its input schema;
2. its output schema.

This differs slightly from action descriptors, where the emphasis is primarily on inputs and resulting effects.

Example conceptual descriptor:

```json
{
  "name": "positions",
  "description": "Returns lending positions for an account",
  "inputs": [
    {
      "name": "account",
      "type": "address"
    }
  ],
  "outputs": [
    {
      "name": "positions",
      "type": "Position[]"
    }
  ]
}
```

A semantic `Position` may include fields such as:

```text
market
asset
suppliedAmount
borrowedAmount
collateralValue
healthFactor
```

The descriptor should provide enough information for a generic client to encode the query and decode its response without protocol-specific frontend code.

---

# 7. Descriptor infrastructure should be shared

The addition of queries reinforces that descriptor design should not be solved only for actions.

The eventual descriptor system should support:

```text
Application Descriptor System
            │
      ┌─────┴─────┐
      │           │
    Query       Action
      │           │
   inputs       inputs
   outputs      effects / output metadata
```

The exact descriptor representation remains unresolved.

Potential approaches include:

- ABI-encoded schemas;
- JSON;
- CBOR;
- content-addressed schemas;
- reuse of or alignment with ERC-7730 semantic concepts.

This should continue to be resolved through prototypes rather than fixed prematurely.

---

# 8. `query()`

```solidity
function query(
    bytes32 queryId,
    bytes calldata parameters
)
    external
    view
    returns (bytes memory result);
```

The query receives application-semantic parameters and returns an encoded semantic result.

Example:

```solidity
query(
    POSITIONS,
    abi.encode(account)
)
```

might return an encoded:

```text
Position[]
```

The descriptor defines how both the input and result are encoded.

---

# 9. No dedicated `account` argument

Unlike actions, queries should not have a special top-level `account` parameter.

The action interface currently uses:

```solidity
prepare(
    bytes32 actionId,
    address account,
    bytes calldata parameters
)
```

because `account` has a specific meaning:

> The account expected to authorize or execute the resulting calls.

Queries do not share this invariant.

Some queries are account-specific:

```text
positions(account)
claimableRewards(account)
portfolio(account)
```

while others are not:

```text
availableMarkets()
protocolTVL()
quote(tokenIn, tokenOut, amount)
proposal(id)
```

Therefore, any account should simply be part of the encoded query parameters when relevant.

---

# 10. Composition with `ExternalRequest`

Queries may invoke the same `ExternalRequest` mechanism as actions.

No query-specific offchain lookup primitive is required.

A query implementation may either return immediately:

```text
query(...)
    ↓
onchain computation
    ↓
result
```

or pause execution:

```text
query(...)
    ↓
ExternalRequest
    ↓
client-mediated HTTP request
    ↓
callback
    ↓
result
```

The caller therefore sees one consistent query abstraction regardless of whether the data source is:

```text
fully onchain
public API
indexed data source
cryptographically verified offchain source
permissioned API
user-authenticated API
```

---

# 11. Example: indexed user positions

An application exposes:

```text
defi.lending.positions
```

Input:

```text
account: address
```

Output:

```text
Position[]
```

The application adapter may not be able to enumerate all positions efficiently from current contract state.

Its implementation can therefore invoke:

```text
query("positions", account)
      │
      ▼
ExternalRequest
      │
      ▼
protocol indexer
      │
      ▼
response
      │
      ▼
positionsCallback(...)
      │
      ▼
Position[]
```

From the client's perspective, it remains simply:

```text
positions(account) → Position[]
```

The fact that indexing infrastructure was involved is an implementation detail.

---

# 12. Example: authenticated portfolio query

Consider an application exposing private or account-specific analytics:

```text
app.portfolio.summary
```

Inputs:

```text
wallet: address
```

Outputs:

```text
totalValue
pnl24h
positions[]
```

The resolver may construct:

```solidity
RequestRequirement({
    location: RequestLocation.HEADER,
    path: "Authorization",
    description:
        "Bearer credential accepted by the Example user API",
    sensitive: true
});
```

and revert with:

```solidity
ExternalRequest(
    address(this),
    request,
    this.portfolioCallback.selector,
    abi.encode(wallet)
);
```

The client:

1. validates the `ExternalRequest`;
2. determines whether it can satisfy the `Authorization` requirement;
3. applies credential/origin policy;
4. inserts the private header locally;
5. executes the HTTP request;
6. invokes the callback with the API response;
7. receives the encoded semantic query result.

The authentication credential is never visible to the query resolver.

---

# 13. Example implementation

Conceptually:

```solidity
function query(
    bytes32 queryId,
    bytes calldata parameters
)
    external
    view
    returns (bytes memory)
{
    if (queryId == PORTFOLIO) {
        address account =
            abi.decode(parameters, (address));

        RequestRequirement[] memory requirements =
            new RequestRequirement[](1);

        requirements[0] = RequestRequirement({
            location: RequestLocation.HEADER,
            path: "Authorization",
            description:
                "Bearer credential accepted by the Example portfolio API",
            sensitive: true
        });

        revert ExternalRequest(
            address(this),
            Request({
                url: "https://api.example.com/portfolio",
                method: "POST",
                headers: ...,
                body: ...,
                requirements: requirements
            }),
            this.portfolioCallback.selector,
            abi.encode(account)
        );
    }

    ...
}
```

The continuation:

```solidity
function portfolioCallback(
    bytes calldata response,
    bytes calldata extraData
)
    external
    view
    returns (bytes memory)
{
    address account =
        abi.decode(extraData, (address));

    // Decode and validate external response.

    Portfolio memory portfolio = ...;

    return abi.encode(portfolio);
}
```

The generic client does not need application-specific knowledge beyond the query descriptor.

---

# 14. Queries and actions should remain separate interfaces

Do not merge them into a single large interface.

Recommended direction:

```solidity
interface IApplicationQueries {
    ...
}

interface IApplicationActions {
    ...
}
```

A complete adapter can implement both:

```solidity
contract ProtocolApplicationAdapter
    is IApplicationQueries,
       IApplicationActions
{
    ...
}
```

But implementations may support only one.

For example:

```text
analytics adapter
    → queries only

transaction-builder adapter
    → actions only

full protocol adapter
    → queries + actions
```

Separate interfaces preserve modularity and simpler interface detection.

---

# 15. Rename existing action descriptor function

The current handover uses:

```solidity
descriptor(bytes32 actionId)
```

for the action resolver.

Now that queries introduce their own descriptors, rename this to:

```solidity
actionDescriptor(bytes32 actionId)
```

The action interface should therefore become:

```solidity
interface IApplicationActions {
    function actions()
        external
        view
        returns (bytes32[] memory actionIds);

    function actionDescriptor(
        bytes32 actionId
    )
        external
        view
        returns (bytes memory descriptor);

    function prepare(
        bytes32 actionId,
        address account,
        bytes calldata parameters
    )
        external
        view
        returns (PreparedAction memory);
}
```

This avoids ambiguity when both interfaces are implemented by the same contract.

---

# 16. Updated terminology

The overall architecture should no longer be referred to exclusively as an **Application Action Resolver**.

The broader abstraction is an **Application Interface** or **Application Adapter** exposing two capabilities:

```text
Application Interface
        │
  ┌─────┴─────┐
  │           │
Queries     Actions
```

Possible terminology:

- Application Interface
- Application Adapter
- Protocol Interface
- Application Queries / Application Actions

No final naming decision has been made.

The individual action component can still be referred to as the action resolver.

---

# 17. Agent interaction model

The addition enables a generic agent loop such as:

```text
discover application
        ↓
discover queries
        ↓
query user/application state
        ↓
reason over semantic result
        ↓
discover available actions
        ↓
select action
        ↓
prepare action
        ↓
simulate
        ↓
authorize
        ↓
execute
        ↓
query updated state
```

For example:

```text
query:
    lending.positions(user)
          ↓

query:
    lending.borrowCapacity(user)
          ↓

agent determines:
    rebalance desirable
          ↓

prepare:
    lending.repay(...)
          ↓

Call[]
          ↓

execution
          ↓

query:
    lending.positions(user)
```

This is significantly more useful than exposing only transaction construction.

---

# 18. Relationship to raw blockchain reads

The query interface is not intended to replace:

```text
eth_call
storage inspection
event logs
RPC methods
```

Generic clients should continue using those where appropriate.

The query layer adds value when the application possesses higher-level semantic knowledge.

A query should generally justify its existence by doing one or more of:

- aggregating multiple low-level reads;
- performing application-specific computation;
- using indexed historical data;
- depending on external services;
- normalizing protocol-specific representation;
- providing semantic data that is difficult to infer from the ABI alone.

Avoid exposing trivial semantic wrappers around every contract getter simply for completeness.

---

# 19. Query result freshness

The initial query interface should remain:

```solidity
returns (bytes memory result);
```

Do not add a standardized result wrapper such as:

```solidity
struct QueryResult {
    bytes data;
    uint256 validUntil;
}
```

yet.

Freshness information can initially be represented as part of the query's semantic output where relevant.

Example:

```text
Quote {
    amountOut
    observedAt
    validUntil
}
```

A generic result wrapper should only be introduced if multiple real implementations demonstrate that all or most query results need common freshness metadata.

---

# 20. Security considerations

All existing `ExternalRequest` security requirements apply equally to queries.

Queries introduce additional privacy concerns because they may retrieve user-specific information.

Clients should consider:

- whether invoking the query itself reveals information about user intent;
- whether an account address is being sent to an external API;
- whether authentication credentials are required;
- whether the response contains private data;
- whether the response should be exposed to an AI reasoning layer;
- whether sensitive result data should be logged or cached.

The external-request standard governs request-side secrets, but the query layer may eventually need additional guidance around **sensitive responses**.

This is currently an open issue and should be included in the threat-model phase.

---

# 21. Decisions added by this supplement

The following should be incorporated into the main handover's **Decisions Made So Far** section.

## Application interface

**Current direction**

- The application-level standard should support both semantic **queries** and semantic **actions**.
- Queries and actions should use separate optional interfaces.
- A full application adapter may implement both interfaces.
- Queries should be discoverable via `queries()`.
- Queries should expose descriptors containing both input and output schemas.
- Query inputs should use opaque `bytes parameters`, consistent with the generic action-envelope pattern.
- Queries should return opaque `bytes result`, interpreted according to the descriptor.
- Account/user identity should be an ordinary query parameter rather than a distinguished function argument.
- Queries may invoke `ExternalRequest`.
- No separate query-specific offchain mechanism should be introduced.
- `ExternalRequest` remains shared infrastructure.
- Query semantics should represent application-level information rather than merely wrapping raw contract getters.
- The existing action `descriptor()` function should be renamed `actionDescriptor()`.

**Deferred**

- descriptor serialization;
- canonical query taxonomy;
- standardized query-result freshness metadata;
- sensitive-response metadata;
- query caching semantics;
- canonical application-adapter discovery.

---

# 22. Updated working interfaces

The developer should update the handover's experimental interfaces to approximately:

```solidity
struct Call {
    address target;
    uint256 value;
    bytes data;
}

struct PreparedAction {
    Call[] calls;
    uint256 validUntil;
}

interface IApplicationActions {
    function actions()
        external
        view
        returns (bytes32[] memory actionIds);

    function actionDescriptor(
        bytes32 actionId
    )
        external
        view
        returns (bytes memory descriptor);

    function prepare(
        bytes32 actionId,
        address account,
        bytes calldata parameters
    )
        external
        view
        returns (PreparedAction memory);
}

interface IApplicationQueries {
    function queries()
        external
        view
        returns (bytes32[] memory queryIds);

    function queryDescriptor(
        bytes32 queryId
    )
        external
        view
        returns (bytes memory descriptor);

    function query(
        bytes32 queryId,
        bytes calldata parameters
    )
        external
        view
        returns (bytes memory result);
}
```

Both interfaces may invoke the separately defined:

```solidity
ExternalRequest(...)
```

continuation primitive.

---

# 23. Updated prototype plan

Add query testing to the implementation roadmap.

In addition to the existing action prototypes, implement:

### Query test 1 — entirely onchain

```text
availableMarkets()
```

or another semantic aggregate that can be calculated entirely from contract state.

### Query test 2 — public indexed data

```text
positions(account)
```

where enumeration requires an indexer.

### Query test 3 — authenticated API

```text
portfolioSummary(account)
```

requiring a sensitive header via `RequestRequirement`.

### Query test 4 — multi-stage query

```text
query
  ↓
public request
  ↓
callback
  ↓
authenticated request
  ↓
callback
  ↓
semantic result
```

### Query test 5 — action/query composition

Demonstrate:

```text
query state
    ↓
prepare action
    ↓
execute
    ↓
query resulting state
```

using the same generic client.

---

# 24. Updated prototype success criteria

Add the following to the main success criteria:

1. A client can discover supported semantic queries without application-specific code.
2. The client can construct query inputs using only the query descriptor.
3. The client can decode query results using only the descriptor.
4. A semantic query can aggregate multiple onchain data sources.
5. A semantic query can resolve indexed/offchain data through `ExternalRequest`.
6. A semantic query can use a client-owned authenticated API value without exposing it to the resolver contract.
7. The same generic continuation runtime handles external requests originating from both `query()` and `prepare()`.
8. An agent can perform a complete observe → reason → act → observe loop against at least one real application adapter.

---

# 25. Updated architectural thesis

The project should now be framed around making the **application**, rather than merely its transactions, machine-legible.

A smart-contract ABI answers:

> What contract functions can I call?

The proposed application interface answers:

> What can I learn about this application?

and:

> What can I do with this application?

The external-request standard provides the shared execution primitive that allows either answer to depend on hybrid onchain/offchain computation.

The complete abstraction is therefore:

```text
                    Application Adapter
                           │
             ┌─────────────┴─────────────┐
             │                           │
          Queries                     Actions
             │                           │
     "What is true?"             "What can I do?"
             │                           │
             ▼                           ▼
          query()                    prepare()
             │                           │
             └─────────────┬─────────────┘
                           │
                   hybrid computation
                           │
            ┌──────────────┴──────────────┐
            │                             │
         onchain                    ExternalRequest
            │                             │
            │                     external service
            │                             │
            └──────────────┬──────────────┘
                           │
              ┌────────────┴────────────┐
              │                         │
        semantic data              executable calls
```

The broader goal is a generic application interface through which machine clients can both **observe** and **interact with** an application without reproducing its frontend-specific integration logic.

# Technical Handover: Application Interfaces and External Request Standards

**Status:** Working design / pre-EIP
**Purpose:** Capture the problem statement, architecture, decisions made to date, current draft interfaces, unresolved questions, and implementation plan.

> **Integrated update:** The Application Query supplement extends this architecture with a separate optional `IApplicationQueries` capability. The current experimental action interface is named `IApplicationActions`, and its descriptor function is `actionDescriptor()`. The consolidated implementation sequence is maintained in `docs/implementation-plan.md`.

---

## 1. Executive summary

Smart contracts generally expose low-level execution primitives rather than the higher-level actions users understand.

A user thinks in terms of:

- swap ETH for USDC;
- supply collateral;
- borrow the maximum amount while maintaining a health factor;
- add liquidity;
- claim rewards;
- vote on a proposal.

A protocol contract exposes functions, storage, and calldata.

Constructing a valid transaction frequently requires additional information that is not directly available from the contract being called:

- indexed positions;
- routing information;
- quotes;
- protocol metadata;
- API responses;
- user-specific offchain state;
- permissioned API data.

Today this logic usually exists in protocol frontends and backend services. As a result, a generic wallet or AI agent can inspect a contract ABI but often cannot determine:

1. what meaningful actions a user can perform;
2. what semantic parameters those actions require;
3. what external information is necessary;
4. how to obtain that information;
5. how to turn the result into executable EVM calls.

The proposed architecture introduces two separable standards:

### A. Application Interfaces

A protocol adapter may publish machine-readable semantic queries, high-level actions, or both. Queries return structured application data; actions resolve semantic parameters into executable call bundles.

```text
semantic action
      ↓
IApplicationActions
      ↓
PreparedAction
      ↓
Call[]
```

### B. External Request

A generic revert/callback mechanism allows Solidity execution to pause when client-mediated external information is required.

Unlike ERC-3668 CCIP Read, the external request can describe an arbitrary HTTP request and declare values that must be supplied by the client in headers, query parameters, or structured request bodies.

```text
contract execution
      ↓
ExternalRequest
      ↓
client completes request
      ↓
HTTP
      ↓
response
      ↓
contract callback
      ↓
execution continues
```

The two standards are designed to compose but remain independently useful.

---

# 2. Problem statement

Onchain application contracts tend to be lean.

This is desirable for cost, security, and composability, but it means that the information required to construct transactions often lives elsewhere.

For example, a swap frontend may need to:

```text
read pool/indexer state
      ↓
calculate route
      ↓
obtain quote
      ↓
calculate slippage bound
      ↓
determine approval strategy
      ↓
construct router calldata
```

A lending frontend may need:

```text
load user positions
      ↓
load prices and risk parameters
      ↓
calculate borrowing capacity
      ↓
select protocol parameters
      ↓
construct calldata
```

The smart contract ABI alone does not encode this application-level knowledge.

This creates a machine-legibility problem.

A generic agent can understand that a contract exposes:

```solidity
function execute(bytes calldata commands, bytes[] calldata inputs)
```

without having any reliable way to determine that this can be used to achieve:

> “Swap 1 ETH for as much USDC as possible with no more than 50 bps slippage.”

The objective is therefore not simply to expose contract functions.

The objective is to expose **application affordances**.

---

# 3. Design goals

The system should:

1. Make high-level application actions discoverable by generic clients.
2. Express semantic user inputs independently of protocol-specific calldata.
3. Resolve those inputs into executable EVM calls.
4. Support existing immutable protocols through separate adapter contracts.
5. Work for completely onchain applications.
6. Work for applications requiring public offchain data.
7. Work for applications requiring permissioned or user-authenticated APIs.
8. Keep secrets and client-private values out of smart-contract execution.
9. Allow protocol-specific logic without requiring generic clients to understand it.
10. Avoid embedding today's authentication protocols into the core standard.
11. Reuse existing Internet and Ethereum standards where they match the required semantics.
12. Keep the base interfaces small enough to implement and validate against real protocols.

---

# 4. Non-goals for the initial version

The initial standard should not attempt to solve:

- a universal DeFi intent language;
- execution or wallet authorization;
- solver selection;
- canonical action naming across the ecosystem;
- canonical resolver discovery/authenticity;
- OAuth itself;
- API-key provisioning;
- generic credential management;
- arbitrary binary request templating;
- every possible request transport;
- transaction simulation;
- account-abstraction standards;
- cross-chain action orchestration unless required by implementation experience.

These may compose with the standard or become future extensions.

---

# 5. Architectural principles

## 5.1 The resolver is a compiler

The most useful mental model is:

```text
semantic application request
          ↓
      resolver
          ↓
protocol-specific EVM calls
```

For example:

```text
swap:
    tokenIn = WETH
    tokenOut = USDC
    amount = 1 ETH
    maxSlippage = 50 bps
```

might compile into:

```text
Permit2.approve(...)
UniversalRouter.execute(...)
```

The client does not need protocol-specific knowledge about the Universal Router encoding.

---

## 5.2 Application semantics and execution are separate

The action standard should output calls but should not dictate how they are executed.

The output may be consumed by:

- an EOA wallet;
- a smart account;
- ERC-4337 infrastructure;
- EIP-5792-style wallet calls;
- Safe;
- a simulator;
- an agent policy engine.

---

## 5.3 Offchain access is an implementation detail of resolution

A resolver that can operate entirely from onchain state should simply return.

A resolver that requires external information can pause resolution using the external-request mechanism.

The public action interface remains identical.

```text
                     prepare()
                        │
             ┌──────────┴──────────┐
             │                     │
       enough onchain       external data needed
             │                     │
             ▼                     ▼
          Call[]           ExternalRequest
                                   │
                                   ▼
                              callback
                                   │
                                   ▼
                                Call[]
```

---

## 5.4 The client owns private context

A smart contract may describe that an external request requires:

```text
Authorization header
API key
account identifier
session identifier
```

but it should never receive the corresponding value.

The resolver defines **what is required**.

The client decides:

- whether it possesses the value;
- whether it is permitted to use it;
- whether it is safe to send to the specified endpoint;
- whether user authorization is necessary.

---

# 6. Proposed standard A: Application Actions

## 6.1 Current minimal interface

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

    function actionDescriptor(bytes32 actionId)
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

This is a working interface, not a frozen ABI.

## 6.2 Complementary query interface

```solidity
interface IApplicationQueries {
    function queries()
        external
        view
        returns (bytes32[] memory queryIds);

    function queryDescriptor(bytes32 queryId)
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

Queries are semantic application reads rather than wrappers around arbitrary contract getters. Their descriptors define both input and output schemas. Account identity is included in `parameters` when relevant rather than receiving a distinguished ABI argument. Queries may use the same External Request continuation mechanism as actions.

Queries and actions remain separate optional interfaces so analytics-only, action-only, and complete application adapters are all possible.

---

# 7. Action discovery

## `actions()`

```solidity
function actions()
    external
    view
    returns (bytes32[] memory actionIds);
```

answers:

> What application-level actions does this resolver expose?

Examples might include:

```text
swap
addLiquidity
removeLiquidity
supply
withdraw
borrow
repay
claimRewards
```

The purpose is to expose **user affordances**, rather than mirror every contract function.

A router may expose low-level functions such as:

```text
execute
settle
take
unlock
```

while its resolver exposes:

```text
swap tokens
add liquidity
remove liquidity
collect fees
```

### Action identifier format

The final action-ID convention is not yet decided.

A likely starting point is:

```solidity
keccak256("defi.swap.exactInput")
```

but canonical ecosystem-wide namespaces are explicitly deferred.

---

# 8. Action descriptors

## `actionDescriptor()`

```solidity
function actionDescriptor(bytes32 actionId)
    external
    view
    returns (bytes memory descriptor);
```

describes:

- what the action does;
- what parameters it requires;
- parameter types;
- semantic meaning;
- constraints;
- possibly effects or prerequisites.

For example, conceptually:

```json
{
  "name": "swap",
  "description": "Exchange one token for another",
  "inputs": [
    {
      "name": "tokenIn",
      "type": "address",
      "semanticType": "erc20"
    },
    {
      "name": "tokenOut",
      "type": "address",
      "semanticType": "erc20"
    },
    {
      "name": "amountIn",
      "type": "uint256",
      "semanticType": "tokenAmount"
    },
    {
      "name": "maxSlippage",
      "type": "uint256",
      "semanticType": "basisPoints"
    }
  ]
}
```

### Not yet decided

The descriptor serialization format is intentionally unresolved.

Candidates include:

- ABI-encoded structures;
- JSON;
- CBOR;
- content-addressed metadata;
- reuse/alignment with ERC-7730 concepts.

This should be determined through implementation rather than prematurely standardized.

---

# 9. Action preparation

## `prepare()`

```solidity
function prepare(
    bytes32 actionId,
    address account,
    bytes calldata parameters
)
    external
    view
    returns (PreparedAction memory);
```

takes a semantic action and compiles it into executable calls.

### `account`

The intended account is explicit rather than inferred from `msg.sender`.

This is necessary because `prepare()` will normally be invoked using `eth_call`, potentially by:

- an RPC provider;
- an AI-agent runtime;
- a wallet backend;
- a simulator;
- a bundler.

Preparation may depend on account-specific state such as:

- balances;
- approvals;
- protocol positions;
- smart-account capabilities;
- collateral;
- delegation;
- permits.

---

## 9.1 Why parameters are opaque bytes

The common interface should not require one Solidity function per action.

Instead:

```solidity
prepare(actionId, account, parameters)
```

provides a generic envelope.

The action descriptor defines how `parameters` should be encoded and interpreted.

This gives generic infrastructure one stable ABI while allowing protocol-specific action schemas.

---

# 10. Prepared action

```solidity
struct PreparedAction {
    Call[] calls;
    uint256 validUntil;
}
```

## `calls`

A single calldata blob is insufficient because an application action may require multiple calls.

Example:

```text
USDC.approve(vault, amount)
vault.deposit(amount, account)
```

The call representation is therefore:

```solidity
struct Call {
    address target;
    uint256 value;
    bytes data;
}
```

The resolver constructs calls but does not execute them.

## `validUntil`

Prepared transactions may depend on ephemeral state such as:

- prices;
- quotes;
- routes;
- available liquidity;
- user state.

`validUntil` lets a resolver declare that the prepared result should be regenerated after a specific time.

### Deferred fields

Earlier designs considered:

```text
validAfter
contextHash
requestHash
validate()
```

These are not currently included.

They should only be added if implementation experience demonstrates a concrete requirement.

---

# 11. Existing protocol compatibility

The action interface does not require modification to the target protocol.

A separate resolver/adaptor contract may be deployed:

```text
existing immutable protocol
          ↑
          │ calls constructed for
          │
   Action Resolver
          ↑
          │
        agent
```

This allows existing protocols to become machine-legible without upgrading their core contracts.

Resolver authenticity and canonical discovery remain separate unresolved problems.

---

# 12. Proposed standard B: External Request

The external-request standard allows contract computation to request a client-mediated external HTTP interaction.

The current direction is to define a **new revert-based standard**, rather than extending ERC-3668's `OffchainLookup` wire format.

ERC-3668 remains an important architectural precedent.

It defines a revert → gateway → callback continuation mechanism, carries opaque `extraData`, validates that the `sender` matches the contract that generated the lookup, and permits recursive lookups.

However, its defined HTTPS transport assumes either a templated GET or a JSON POST containing `sender` and opaque `callData`. `callData` is intentionally opaque to clients.

That is incompatible with the richer client-mediated request semantics required here.

ERC-7412 provides precedent for defining a different revert-based offchain-data mechanism when the desired semantics differ materially from ERC-3668.

---

# 13. External Request working ABI

```solidity
struct Header {
    string name;
    string value;
}

enum RequestLocation {
    HEADER,
    QUERY,
    BODY
}

struct RequestRequirement {
    RequestLocation location;
    string path;
    string description;
    bool sensitive;
}

struct Request {
    string url;
    string method;
    Header[] headers;
    bytes body;
    RequestRequirement[] requirements;
}

error ExternalRequest(
    address sender,
    Request request,
    bytes4 callbackFunction,
    bytes extraData
);
```

This ABI is a working draft.

---

# 14. Request model

A `Request` is a mostly complete HTTP request produced by the resolver.

```solidity
struct Request {
    string url;
    string method;
    Header[] headers;
    bytes body;
    RequestRequirement[] requirements;
}
```

The resolver controls:

- destination URL;
- HTTP method;
- public headers;
- body template.

The client supplies only explicitly declared missing values.

---

# 15. Headers

```solidity
struct Header {
    string name;
    string value;
}
```

`Content-Type` is represented as a normal HTTP header.

There is deliberately no separate:

```solidity
string contentType;
```

because this would duplicate HTTP semantics and allow conflicting values.

Example:

```text
Content-Type: application/json
Accept: application/json
```

Header names must be treated case-insensitively in accordance with HTTP semantics.

A client should reject ambiguous/conflicting `Content-Type` values when body interpolation depends upon the media type.

---

# 16. Request requirements

```solidity
struct RequestRequirement {
    RequestLocation location;
    string path;
    string description;
    bool sensitive;
}
```

A requirement means:

> The resolver requires a client-owned value at this request location in order for the request to be executed.

It does **not** identify a particular credential or tell the resolver how to retrieve one.

This intentionally avoids enshrining authentication systems such as:

```text
OAuth2
API_KEY
SIWE
Bearer
mTLS
```

into the core standard.

Those systems can be described in plaintext and handled above the transport layer.

---

# 17. Requirement locations

The initial supported locations are:

```solidity
enum RequestLocation {
    HEADER,
    QUERY,
    BODY
}
```

This decision replaced the earlier auth-specific design because client-owned values are not necessarily credentials.

Examples include:

- API keys;
- access tokens;
- institutional account identifiers;
- organization IDs;
- session identifiers;
- user-specific API context.

OpenAPI is useful precedent for treating request placement independently of credential semantics; for example, it models API keys as potentially occurring in headers, query parameters, or cookies.

The current proposal deliberately uses a more general request-value abstraction.

---

# 18. `HEADER` requirements

For:

```text
location = HEADER
```

`path` is the HTTP header field name.

Example:

```text
location:
    HEADER

path:
    Authorization

description:
    Bearer access token accepted by the Foo quote API

sensitive:
    true
```

The client may satisfy this with:

```text
Authorization: Bearer ********
```

The resolver never sees the value.

---

# 19. `QUERY` requirements

For:

```text
location = QUERY
```

`path` is the query parameter name.

Example:

```text
location:
    QUERY

path:
    account_id

description:
    Foo institutional account identifier

sensitive:
    false
```

The client structurally adds the query parameter to the URL.

Clients must not perform naïve string concatenation; URL escaping and query encoding must be deterministic.

Sensitive query values require special care because URLs are commonly exposed through logs, browser history, monitoring systems, and intermediary infrastructure. RFC 6750 specifically warns against placing bearer tokens in URLs for these reasons.

A final specification should likely state that clients SHOULD warn or apply policy before inserting sensitive query values.

---

# 20. `BODY` requirements

`BODY` insertion semantics depend on the request's `Content-Type`.

The base specification should initially define only a small number of structured media types.

## JSON

For:

```text
Content-Type: application/json
```

`path` should use RFC 6901 JSON Pointer.

RFC 6901 defines a standard string syntax for identifying a value within a JSON document.

Example:

```text
location:
    BODY

path:
    /credentials/apiKey
```

might transform:

```json
{
  "token": "ETH"
}
```

into:

```json
{
  "token": "ETH",
  "credentials": {
    "apiKey": "<CLIENT_VALUE>"
  }
}
```

Precise creation-vs-replacement semantics still need to be specified.

## Form encoding

For:

```text
Content-Type: application/x-www-form-urlencoded
```

`path` represents the form-field name.

Example:

```text
path:
    api_key
```

would insert an `api_key` form value.

## Other body formats

If the client does not understand the declared media type sufficiently to perform deterministic insertion, it must not guess.

The request should fail as an unsupported requirement unless another specification defines insertion semantics for that media type.

This provides an extension mechanism for future formats such as:

- CBOR;
- XML;
- protobuf-derived representations;
- vendor-specific media types.

---

# 21. Why `description` is plaintext

The design intentionally prefers extensibility over a rigid authentication taxonomy.

For example:

```text
path:
    Authorization

description:
    Bearer token authorized for Foo's institutional quote API
```

rather than:

```text
authType = OAUTH2
scope = ...
resource = ...
```

A future authentication mechanism can therefore be used without revising this standard.

The generic protocol only needs to know:

> A client-provided value is required here.

Higher-level runtimes may use the description to:

- identify a stored credential;
- ask a user;
- invoke an OAuth flow;
- use a connector;
- refuse the request.

The standard does not define credential acquisition.

---

# 22. Sensitive values

`sensitive` indicates that the requested value should receive stronger privacy treatment.

Examples:

```text
API key               sensitive = true
Bearer token          sensitive = true
organization ID       potentially false
public wallet address false
```

The exact implications of `sensitive = true` should be made normative during the next specification phase.

At minimum, sensitive values should never automatically enter:

- contract calldata;
- `extraData`;
- callback response data;
- logs;
- chain state;
- diagnostic output.

---

# 23. External request control flow

A compliant client should conceptually execute:

```text
eth_call target
      │
      ├── success
      │      ↓
      │   return result
      │
      └── ExternalRequest
             │
             ▼
       validate sender
             │
             ▼
        decode Request
             │
             ▼
   resolve RequestRequirement[]
             │
             ▼
     construct HTTP request
             │
             ▼
          execute
             │
             ▼
       obtain response
             │
             ▼
eth_call sender.callback(response, extraData)
             │
             ├── success → return
             │
             └── ExternalRequest → repeat
```

---

# 24. `sender`

```solidity
address sender
```

should preserve the useful security semantics of ERC-3668.

ERC-3668 uses `sender` to ensure that an `OffchainLookup` bubbling from a nested call is not incorrectly interpreted as a lookup initiated by the top-level contract.

A client handling `ExternalRequest` should verify:

```text
error.sender == address currently being called
```

before performing the external interaction.

The exact nested-call rules should be reviewed carefully against ERC-3668 before freezing the standard.

---

# 25. Callback semantics

The callback should retain the CCIP-style continuation model.

Conceptually:

```solidity
function callback(
    bytes calldata response,
    bytes calldata extraData
)
    external
    view
    returns (...);
```

`response` contains the external service response.

`extraData` contains resolver-controlled continuation state and must be passed back unchanged.

ERC-3668 uses the same model and explicitly permits the callback to initiate another offchain lookup.

That is desirable here as well.

Example:

```text
prepare()
   ↓
external indexer request
   ↓
callback1()
   ↓
authenticated quote request
   ↓
callback2()
   ↓
PreparedAction
```

Clients must impose a recursion/depth limit.

ERC-3668 similarly requires clients to limit repeated lookups and recommends supporting at least four.

The exact limit for this standard remains open.

---

# 26. Why this is not currently an ERC-3668 extension

The current design decision is:

> Reuse the architectural lessons of ERC-3668, but define a distinct external-request signal.

Reasons:

### 1. Existing CCIP clients would not understand the richer request anyway

ERC-3668 HTTPS clients expect the standard CCIP GET/POST gateway behavior.

They cannot natively interpret:

```text
RequestRequirement[]
JSON-body insertion
client-owned authentication values
```

Supporting these features already requires new client behavior.

### 2. The security boundary is different

Traditional CCIP resolution can often happen transparently.

An external request requiring a user's API token should not.

A distinct revert selector allows clients to recognize that the operation may involve private client context and apply additional authorization policy.

### 3. The abstraction is different

CCIP Read is fundamentally gateway-oriented:

```text
opaque callData → gateway → opaque response
```

The proposed primitive is request-oriented:

```text
request template
+
client-owned values
→
external request
→
response
```

### 4. Ethereum precedent exists

ERC-7412 explicitly defines an alternative revert-based mechanism rather than forcing its differing offchain-data semantics through ERC-3668.

### Compatibility position

This does not prohibit an `IApplicationActions` or `IApplicationQueries` implementation from separately using ERC-3668 when ordinary CCIP Read is sufficient.

The action layer should not care which offchain mechanism an implementation uses.

---

# 27. Single-request semantics

The current design intentionally does **not** include:

```solidity
RequestAlternative[]
```

A lookup requests one concrete external operation.

If a protocol provides meaningfully different alternatives such as:

```text
public quote
authenticated institutional quote
premium RFQ quote
```

those can be exposed as separate application actions or action variants.

This preserves a useful separation:

```text
action layer:
    decides what interaction should happen

external-request layer:
    deterministically executes one required request
```

The generic transport runtime should not become a solver deciding among API strategies.

A single URL is therefore the current minimal direction.

Multi-endpoint gateway failover can be revisited if concrete implementations demonstrate a need.

---

# 28. Security invariants

These should be treated as protocol requirements, not optional implementation advice.

## 28.1 Client-owned values remain client-side

A resolver MUST NOT receive values used to satisfy `RequestRequirement` unless another explicit protocol defines such disclosure.

The intended flow is:

```text
contract
   ↓ request requirement

client
   ↓ privately obtains value

HTTP request
   ↓

service
```

not:

```text
client secret
   ↓
contract
   ↓
HTTP
```

---

## 28.2 Requirements are not arbitrary credential references

The resolver should not be able to say:

```text
give me credential ID 123
```

It can only say:

```text
this request requires a value here,
described as X
```

The client retains responsibility for deciding whether and how to satisfy it.

---

## 28.3 Origin policy

A client must decide whether a sensitive value may be sent to the request origin.

A malicious resolver must not be able to exfiltrate credentials simply by declaring:

```text
Authorization
→ https://attacker.example
```

The final specification needs explicit origin/resource-scoping requirements.

---

## 28.4 Redirect policy

Sensitive values MUST NOT automatically follow a cross-origin redirect.

A redirect to a different origin should require a new authorization decision or fail.

---

## 28.5 Network targeting / SSRF

Clients need policy around:

- localhost;
- loopback;
- private network ranges;
- metadata services;
- internal corporate networks;
- unusual schemes/ports.

External requests originate from potentially untrusted contract code.

This threat model must be explicit.

---

## 28.6 Query leakage

Sensitive query parameters should be discouraged or subject to stronger client policy because URLs frequently appear in logs and histories. RFC 6750 provides useful security precedent here.

---

## 28.7 Response trust

The existence of an external request mechanism does not imply that the external response is trustworthy.

The callback is responsible for applying whatever validation the application requires:

- signature verification;
- proof verification;
- deadline checks;
- asset matching;
- requested-account matching;
- response bounds;
- quote validation.

This follows the same useful model as ERC-3668, where the callback is responsible for decoding and validating gateway data.

---

# 29. Example: authenticated quote

An action resolver receives:

```text
Action:
    institutionalSwap

Parameters:
    tokenIn = WETH
    tokenOut = USDC
    amountIn = 1 ETH
```

It requires an authenticated quote and reverts:

```solidity
ExternalRequest(
    address(this),
    Request({
        url: "https://api.example.com/v1/quote",
        method: "POST",
        headers: [
            Header("Content-Type", "application/json")
        ],
        body: bytes(
            '{"tokenIn":"WETH","tokenOut":"USDC","amount":"1000000000000000000"}'
        ),
        requirements: [
            RequestRequirement({
                location: RequestLocation.HEADER,
                path: "Authorization",
                description: "Bearer credential accepted by Example institutional API",
                sensitive: true
            }),
            RequestRequirement({
                location: RequestLocation.BODY,
                path: "/accountId",
                description: "Example institutional account identifier",
                sensitive: false
            })
        ]
    }),
    this.quoteCallback.selector,
    abi.encode(
        account,
        tokenIn,
        tokenOut,
        amountIn
    )
);
```

The client:

1. validates the request;
2. locates an acceptable credential;
3. inserts the `Authorization` header;
4. inserts `/accountId` into the JSON body;
5. sends the HTTP request;
6. passes the response and unchanged `extraData` to `quoteCallback()`.

The callback validates the quote and returns:

```solidity
PreparedAction({
    calls: ...,
    validUntil: ...
});
```

At no point does the resolver receive the bearer token.

---

# 30. Example: fully onchain action

The same `IApplicationActions` interface can expose an action that requires no external request:

```solidity
function prepare(
    bytes32 actionId,
    address account,
    bytes calldata parameters
)
    external
    view
    returns (PreparedAction memory prepared)
{
    // Read onchain state.
    // Compute calldata.
    // Return directly.
}
```

This preserves the desired decentralization spectrum:

```text
fully onchain
public offchain
proof-backed offchain
permissioned API
user-authenticated API

          ↓

same IApplicationActions interface
```

---

# 31. Decisions made so far

## Application interface

**Decided / current direction**

- Application adapters may expose semantic queries, semantic actions, or both through separate optional interfaces.
- `IApplicationQueries` discovers queries, describes their input and output schemas, and returns encoded semantic results.
- Query account identity is an ordinary encoded parameter rather than a distinguished ABI argument.
- Queries and actions share External Request and should eventually share descriptor infrastructure.
- The action interface is named `IApplicationActions`; its descriptor function is `actionDescriptor()`.

**Deferred**

- query-result freshness wrappers;
- sensitive-result metadata and handling;
- query caching semantics;
- canonical application-adapter discovery.

## Action layer

**Decided / current direction**

- High-level actions should be represented independently of low-level protocol functions.
- The standard should define an EVM ABI, not require Solidity as the implementation language.
- Solidity will likely be used for reference implementations.
- Existing protocols should be supportable through separate resolver contracts.
- The intended user/account should be passed explicitly.
- Generic `prepare(actionId, account, bytes parameters)` is preferred over one function per action.
- Resolution should return `Call[]`, not a single calldata blob.
- The action layer should not dictate wallet/execution behavior.
- `PreparedAction` should include an expiry mechanism such as `validUntil`.
- Offchain resolution is an implementation detail of `prepare()`.

**Deferred**

- canonical action taxonomy;
- descriptor serialization;
- resolver discovery/authenticity;
- cross-chain call representation;
- signature requirements;
- `validate()` function;
- `validAfter`;
- request/context hashes.

---

## External-request layer

**Decided / current direction**

- Define a new revert-based external-request primitive rather than overloading ERC-3668.
- Retain the useful CCIP concepts of:
  - revert-based continuation;
  - `sender`;
  - callback selector;
  - opaque `extraData`;
  - recursive continuation.
- Model a single concrete HTTP request.
- No `RequestAlternative[]`.
- Protocols may expose separate actions when they offer materially different request strategies.
- Request method should remain a string rather than a closed enum.
- `Content-Type` belongs in ordinary headers.
- Client-owned request values use `RequestRequirement`.
- Requirements support:
  - `HEADER`;
  - `QUERY`;
  - `BODY`.
- Requirement semantics should remain plaintext/extensible rather than enumerating authentication systems.
- Body interpolation is determined by `Content-Type`.
- JSON body paths should use RFC 6901 JSON Pointer.
- Sensitive values remain entirely client-side.

---

# 32. Important unresolved questions

These should be resolved through prototypes rather than abstract debate where possible.

## 32.1 Requirement value representation

How does the client represent the value used to satisfy a requirement?

Possibilities include:

```text
string
bytes
typed JSON value
location-specific type
```

This becomes especially important for JSON body insertion.

An API key is naturally a string, but future values may be:

```text
number
boolean
object
array
```

A minimal solution may deliberately support strings first.

---

## 32.2 JSON insertion semantics

RFC 6901 identifies a location but does not itself fully define the mutation behavior required here.

The specification must decide:

- replacement vs creation;
- behavior when parent objects do not exist;
- arrays;
- the special `-` token;
- duplicate/conflicting requirements;
- JSON value typing.

---

## 32.3 Response representation

Should:

```solidity
bytes response
```

contain:

- raw HTTP response body only;
- status + headers + body;
- a structured `Response` object?

The callback may need HTTP status or headers in some applications.

This should be tested against real integrations before deciding.

---

## 32.4 HTTP errors

Need normative behavior for:

```text
3xx
4xx
5xx
timeout
DNS error
TLS error
unsupported media type
unsatisfied requirement
```

Some failures belong at the transport layer and should never reach the callback; others may be useful application data.

---

## 32.5 Request redirects

Need exact rules for:

- same-origin redirects;
- cross-origin redirects;
- method rewriting;
- sensitive-value propagation.

---

## 32.6 Nested external requests

Need exact sender semantics and recursion rules, informed by ERC-3668's nested-call handling.

---

## 32.7 Single URL vs equivalent mirrors

Current minimal direction uses one URL.

This should be validated against real availability/decentralization requirements before freezing the ABI.

---

## 32.8 Action descriptors

This remains the largest unresolved part of the action standard itself.

A real implementation needs enough metadata for a generic agent to distinguish:

```text
uint256 token amount
uint256 timestamp
uint256 percentage
uint256 ID
```

without protocol-specific prior knowledge.

---

# 33. Next steps

The recommended process is specification-through-implementation.

---

## Phase 1 — Freeze a temporary v0 interface

Create a repository containing:

```text
contracts/
    IApplicationActions.sol
    IApplicationQueries.sol
    IExternalRequest.sol

spec/
    ACTIONS.md
    EXTERNAL_REQUEST.md

src/
    client/

test/
```

Mark the ABIs as experimental.

Avoid optimizing calldata/gas layout at this stage.

---

## Phase 2 — Write the External Request normative specification

This should happen before further expanding the application query or action interfaces.

Define:

1. `ExternalRequest` ABI.
2. `Request` ABI.
3. `RequestRequirement` ABI.
4. sender validation.
5. request construction.
6. requirement satisfaction.
7. header insertion.
8. query insertion.
9. JSON-body insertion.
10. form-body insertion.
11. callback construction.
12. recursive lookups.
13. redirects.
14. HTTP error handling.
15. unsupported requirements.
16. security requirements.

The output should be precise enough for two independent client implementations to produce the same HTTP request.

---

## Phase 3 — Implement a minimal reference client

Build a small TypeScript reference implementation before wallet integrations.

Conceptually:

```typescript
async function resolveCall(call) {
    for (;;) {
        try {
            return await ethCall(call);
        } catch (error) {
            if (!isExternalRequest(error)) throw error;

            const lookup = decodeExternalRequest(error);

            assertSenderMatches(call.to, lookup.sender);

            const completedRequest =
                await satisfyRequirements(lookup.request);

            const response =
                await executeHttpRequest(completedRequest);

            call = {
                to: lookup.sender,
                data: encodeCallback(
                    lookup.callbackFunction,
                    response,
                    lookup.extraData
                )
            };
        }
    }
}
```

The first version can use a callback interface such as:

```typescript
resolveRequirement(requirement, requestContext)
```

without standardizing how credentials are stored.

---

# 34. Phase 4 — Build test contracts

Implement deliberately small test cases.

## Test 1: no external request

```text
prepare()
→ Call[]
```

## Test 2: public external request

```text
prepare()
→ ExternalRequest
→ unauthenticated HTTP
→ callback
→ Call[]
```

## Test 3: header requirement

```text
Authorization
```

## Test 4: query requirement

```text
account_id
```

## Test 5: JSON-body requirement

```text
/credentials/apiKey
```

## Test 6: form-body requirement

```text
api_key
```

## Test 7: nested requests

```text
prepare
→ request A
→ callback A
→ request B
→ callback B
→ Call[]
```

## Test 8: malicious request

Attempt:

```text
sensitive credential
→ attacker origin
```

and verify client policy prevents unintended disclosure.

---

# 35. Phase 5 — Implement real application adapters

The objective is not broad protocol coverage but architectural stress testing.

Choose integrations that exercise different requirements.

Suggested categories:

### Fully onchain

A swap or vault action whose calldata can be constructed entirely from chain state.

### Public API

An aggregator requiring an external quote but no client-owned credential.

### Authenticated API

An RFQ or account-specific endpoint requiring an `Authorization` header.

### Body-context API

An endpoint requiring user/account context inside JSON.

### Stateful lending action

Something semantically richer, e.g.:

> Borrow the maximum USDC amount while maintaining health factor ≥ 1.5.

This tests whether the action layer can express constraints rather than simply re-encode ABI arguments.

---

# 36. Phase 6 — Threat model and adversarial implementation review

Before EIP submission, explicitly test:

- credential exfiltration;
- cross-origin redirects;
- localhost requests;
- cloud metadata endpoints;
- DNS rebinding;
- malformed URLs;
- duplicate headers;
- duplicate requirements;
- conflicting body requirements;
- malicious JSON pointers;
- huge responses;
- recursive request exhaustion;
- untrusted callbacks;
- quote replay;
- stale responses;
- arbitrary resolver deployment pretending to represent a protocol.

This should result in a dedicated security section rather than informal implementation guidance.

---

# 37. Phase 7 — Stabilize the interfaces

After the reference client and real integrations exist, revisit every ABI field.

For each field ask:

> Is there a real implementation that requires this?

and:

> Did a real implementation require something we omitted?

Only then should the ABI be optimized and frozen.

Likely review targets:

```text
string vs bytes
enum sizes
struct nesting
response representation
single URL
validUntil
chainId in Call
descriptor format
requirement value typing
```

---

# 38. Phase 8 — Split into EIP/ERC proposals

Assuming implementation validates the architecture, prepare two proposals.

## Proposal A: External Request

Position it as:

> A standard continuation mechanism allowing contract calls to request client-mediated HTTP interactions containing resolver-provided data and client-provided request values.

This proposal should stand independently from AI agents.

Potential users include:

- smart-contract action resolvers;
- identity systems;
- permissioned data interfaces;
- compliance systems;
- authenticated APIs;
- arbitrary hybrid applications.

## Proposal B: Application Interfaces

Position it as:

> Separate optional interfaces for discovering semantic application queries and actions, returning structured application data, and resolving semantic user inputs into executable EVM call bundles.

It may reference External Request as an optional mechanism used during querying or preparation.

---

# 39. Suggested immediate deliverables

The next concrete work should produce the following artifacts, in order:

### 1. `IExternalRequest.sol`

Minimal experimental interface.

### 2. `EXTERNAL_REQUEST.md`

Normative client algorithm and request interpolation rules.

### 3. TypeScript reference client

Working recursive continuation loop.

### 4. External-request test contract

Includes header, query, JSON-body, and nested examples.

### 5. `IApplicationActions.sol`, `IApplicationQueries.sol`, `ACTIONS.md`, and `QUERIES.md`

Minimal experimental interfaces and normative drafts.

### 6. Query and action fixture adapter

Includes onchain, public external, authenticated, and multi-stage query paths plus onchain and externally quoted action paths.

### 7. Two or three real application adapters

Chosen specifically to stress the design.

At least one should support an observe, act, and observe-again vertical slice.

### 8. Shared descriptor prototype

Validates query inputs and outputs together with action inputs and effects before selecting a serialization format.

### 9. Security/threat-model document

Created from actual implementation findings.

### 10. Draft EIPs

Only after the interfaces survive the prototypes.

---

# 40. Success criteria for the prototype phase

The design should not proceed to a formal standard until the following can be demonstrated:

1. A generic client discovers an action without protocol-specific frontend code.
2. The client encodes semantic parameters using only the action descriptor.
3. A fully onchain resolver returns a valid call bundle.
4. The same client handles a resolver requiring external data.
5. The same client handles a resolver requiring a private client-supplied value.
6. That private value is never exposed to the resolver contract.
7. JSON/header/query requirements are deterministic across implementations.
8. Nested external requests work.
9. Returned calls can be simulated and executed by an ordinary wallet/smart account.
10. At least one nontrivial real protocol action is significantly easier for a generic agent to execute through the resolver than through raw ABI inspection.
11. A generic client discovers semantic queries without application-specific code.
12. The client constructs query inputs and decodes results using descriptors alone.
13. A semantic query aggregates multiple onchain sources.
14. A semantic query resolves indexed or external data through External Request.
15. A query uses a client-owned authenticated value without exposing it to the adapter.
16. The same continuation runtime handles external requests from `query()` and `prepare()`.
17. Sensitive query results are subject to explicit logging, caching, and disclosure policy.
18. At least one real adapter demonstrates an observe, reason, act, and observe-again loop.

If these hold, there is strong evidence that the abstraction is addressing a real missing layer rather than merely relocating frontend logic.

---

# 41. Current conceptual architecture

```text
                     User / AI Agent
                           │
                           │ semantic goal
                           ▼
                    Action Descriptor
                           │
                           ▼
                 IApplicationActions
                        prepare()
                           │
              ┌────────────┴────────────┐
              │                         │
       sufficient onchain        external data needed
              │                         │
              │                         ▼
              │                 ExternalRequest
              │                         │
              │              ┌──────────┴──────────┐
              │              │                     │
              │       resolver-owned data   client-owned values
              │              │                     │
              │              └──────────┬──────────┘
              │                         │
              │                         ▼
              │                    HTTP request
              │                         │
              │                         ▼
              │                      response
              │                         │
              │                         ▼
              │                      callback
              │                         │
              └────────────┬────────────┘
                           ▼
                     PreparedAction
                           │
                           ▼
                         Call[]
                           │
                           ▼
               simulation / policy layer
                           │
                           ▼
                         wallet
                           │
                           ▼
                         chain
```

---

# 42. Core thesis

The system should make applications machine-legible at the level users actually interact with them.

Smart-contract ABIs describe:

> what functions exist.

The proposed action standard describes:

> what a user can accomplish.

The external-request standard then allows the resolver to depend on real-world application infrastructure—including permissioned and user-authenticated services—without exposing those dependencies or private credentials directly to the contract.

The intended result is a common abstraction across the full spectrum:

```text
fully decentralized onchain application
              ↓
onchain + public offchain data
              ↓
onchain + cryptographically verified data
              ↓
onchain + permissioned API
              ↓
onchain + user-authenticated API
```

without changing the high-level interface consumed by the agent.

That remains the central design goal against which subsequent additions should be evaluated.

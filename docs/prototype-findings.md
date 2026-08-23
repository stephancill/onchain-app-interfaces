# Prototype Findings and Proposed Solutions

## Status

This document consolidates implementation evidence from the External Request client and the Aerodrome, Moonwell, KyberSwap, OpenSea, and Bitrefill adapters. Proposed solutions are design inputs, not frozen ABI changes.

## Coverage Matrix

| Adapter | Queries | Actions | External data | Client secret | Recursive | Executed on fork |
| --- | --- | --- | --- | --- | --- | --- |
| Aerodrome | Pool, LP position, quote | Direct swap | No | No | No | Yes |
| Moonwell | Positions, health, USDC position | Supply USDC | Public API | No | No | Yes |
| KyberSwap | None | Exact-input swap | Public API | No | Yes | Local calls validated |
| OpenSea | Collection stats | Public mint | Authenticated API | `x-api-key` | No | Onchain drop state mocked |
| Bitrefill | Catalog search and detail | None | Authenticated API | `X-Access-Token` | No | Not applicable |

## 1. Shared Descriptors Are Now the Primary Blocker

Text descriptors cannot let a generic client encode adapter structs, decode ABI tuples or JSON, display token units, identify provenance, explain action effects, or apply sensitivity policy.

### Prototype Result

The v0.1 JSON profile in `spec/DESCRIPTORS.md` now describes all 13 capabilities across the five adapters. The TypeScript client:

- validates descriptors with Zod;
- rejects unknown versions, encodings, ABI types, duplicate fields, and malformed constraints;
- generically encodes direct and tuple parameters, including dynamic structs;
- accepts semantic enum labels;
- generically decodes named ABI query results;
- preserves media type, sensitivity, provenance, effect, and atomicity metadata.

End-to-end tests use descriptor-derived parameters for Moonwell, KyberSwap, OpenSea, and Bitrefill and validate every published descriptor.

Inline JSON has a measurable deployment cost. Runtime sizes after adding descriptors include approximately 12.7 KB for Aerodrome, 15.0 KB for Moonwell, 19.5 KB for OpenSea, and 22.9 KB for KyberSwap. KyberSwap has only about 1.6 KB of EIP-170 runtime margin.

### Proposed Solution

Continue evolving the shared descriptor document containing:

- descriptor version and capability kind;
- parameter and result encoding media type;
- ABI tuple components or JSON Schema references;
- semantic types such as address, token amount, basis points, timestamp, URL, and identifier;
- chain and asset context;
- query provenance and freshness fields;
- action effects, constraints, warnings, and expected approvals;
- sensitivity labels for complete results and individual fields.

JSON is inspectable and works for iteration, but complete documents should not necessarily remain inline in production adapters. Prototype content-addressed descriptors or a separate descriptor contract/registry while retaining small inline descriptors where practical. Keep `queryDescriptor()` and `actionDescriptor()` as opaque bytes until retrieval, canonicalization, and authenticity are tested.

The next descriptor work should focus on cross-field constraints, arrays, schema references for JSON bodies, and generic user-facing rendering. Effect and atomicity metadata are currently explanatory and must not be treated as execution authorization.

## 2. Successful EVM Calls Do Not Always Mean Application Success

Moonwell inherits Compound v2 return-code behavior. `mint` and `enterMarkets` may return nonzero error codes without reverting. A wallet can report transaction success while the intended semantic action failed.

### Proposed Solution

Add prepared-action validation as a separate experimental extension rather than immediately enlarging the base ABI. Compare:

1. A `validate(bytes32 actionId, address account, bytes parameters, PreparedAction prepared)` view function called before execution.
2. Descriptor-declared return-value assertions for simulation results.
3. Descriptor-declared postcondition queries evaluated after execution.

Pre-execution validation alone cannot detect nonzero runtime return codes. The prototype should prioritize simulation return assertions plus postcondition queries.

## 3. Multi-Call Atomicity Is Unspecified

Aerodrome may return approval plus swap. Moonwell may return approval, collateral entry, and mint. Sequential EOA execution can leave approvals or collateral settings behind when a later call fails.

### Proposed Solution

Test an optional execution policy:

```text
SEQUENTIAL_ALLOWED
ATOMIC_REQUIRED
```

Clients that cannot satisfy `ATOMIC_REQUIRED` must reject the prepared action. Keep wallet authorization and execution outside the standard, but make the resolver's atomicity requirement machine-readable.

## 4. API Calldata Must Be Treated as Hostile

KyberSwap and OpenSea return executable calldata. Pinning only the target address is insufficient: calldata can change recipient, token, amount, minimum output, fee recipient, or operation selector.

### Proposed Solution

Normatively require callbacks that return API-produced calls to bind every security-relevant field to semantic parameters or verified onchain state. Reference adapters should:

- pin chain and target contracts;
- restrict selectors;
- ABI-decode and canonically re-encode calldata;
- validate recipients, assets, amounts, limits, fees, and native value;
- reject unsupported variants rather than forwarding arbitrary bytes.

This is application-specific and should not be generalized into the External Request transport.

## 5. JSON Is a Significant Onchain Integration Cost

Moonwell can return raw JSON as semantic data, but KyberSwap and OpenSea require Solidity to extract and validate JSON before constructing calls. Full JSON parsing is expensive and difficult to secure.

The prototype's `Json` library is deliberately narrow: bounded top-level field lookup, duplicate rejection, nested-object extraction, and strict address/hex/integer decoding. It is not a general JSON implementation.

### Proposed Solution

Do not standardize an onchain JSON parser. Encourage application APIs or normalization gateways to offer one of:

- ABI-encoded responses;
- canonical CBOR with a constrained schema;
- signed typed payloads whose signer and domain are verified by callbacks.

External Request should continue delivering response bytes and media metadata. Response interpretation belongs to application callbacks and descriptors.

## 6. Recursive Continuations Work

KyberSwap proves that a callback can consume a quote, construct a second POST request containing the exact route object, and then return a final `PreparedAction`. The same generic client needed no Kyber-specific continuation logic.

### Proposed Solution

Keep recursion in the base standard with mandatory client depth limits. Specify that every nested `ExternalRequest.sender` must equal the address currently called and that opaque `extraData` is passed unchanged for that continuation step.

## 7. Existing Client-Owned Credentials Fit the Requirement Model

OpenSea and Bitrefill demonstrate sensitive header requirements. The client supplies the value only after origin authorization, and neither adapters nor callbacks receive it.

### Proposed Solution

Keep authentication taxonomies out of the core ABI. Strengthen normative policy instead:

- credentials must be authorized for the exact origin;
- sensitive values must never be logged, persisted, redirected, or included in callback data;
- requirement descriptions are user-facing context, not credential identifiers.

Credential acquisition remains outside v0.

## 8. Sensitive Results Need Their Own Policy

Request secrecy does not protect response data. Portfolio information, order history, redemption codes, PINs, and eSIM URLs may be private or bearer credentials. Bitrefill catalog results are non-sensitive, so private order and redemption queries were deliberately excluded.

### Proposed Solution

Add descriptor-level result sensitivity before adding a query-result ABI wrapper. Candidate labels:

```text
PUBLIC
PRIVATE
BEARER_SECRET
```

Allow field-level JSON Pointer labels. Clients should require local callback execution for bearer-secret results and prohibit RPC logging, persistence, analytics, and automatic disclosure to reasoning systems.

## 9. Side-Effecting HTTP Does Not Belong in Query or Preparation Resolution

Kyber route building and OpenSea mint building are computational POST requests. Bitrefill invoice creation changes remote state. Retrying simulation or `eth_call` resolution could duplicate remote effects.

### Proposed Solution

Classify requests normatively:

```text
SAFE
IDEMPOTENT
SIDE_EFFECTING
```

The v0 continuation used by `query()` and `prepare()` should permit only `SAFE` requests and explicitly authorized computational POST requests that do not create durable user-visible state. `SIDE_EFFECTING` requests require a separate external-effect protocol with user confirmation, idempotency keys, retry rules, expiry, cost limits, and remote postconditions.

Do not infer safety from the HTTP method alone.

## 10. x402 and SIWX Are Higher-Level Workflows

Bitrefill token acquisition requires a challenge, wallet signature, and secure credential storage. Payment requires 402 negotiation, an EVM payment, a proof-bearing retry, settlement checks, and asynchronous fulfillment. A string header requirement cannot describe the full workflow safely.

### Proposed Solution

Keep x402 and SIWX out of the base External Request ABI. Define optional typed workflow extensions that bind:

- origin, method, URL, and body hash;
- chain, asset, payee, maximum amount, and expiry;
- challenge nonce, URI, CAIP-2 chain, and signature type;
- user approval and retry semantics;
- returned credential or payment-proof handling.

These workflows must never expose bearer credentials to contracts.

## 11. Chain Context Remains External to `Call`

The adapters were intentionally Base-only. OpenSea cross-chain fulfillment could not be represented as one current `PreparedAction` because `Call` has no chain ID and cross-chain steps require sequential confirmation.

### Proposed Solution

Do not add `chainId` until a cross-chain action prototype exists. Treat each current adapter deployment as chain-scoped. Later compare a chain-aware call bundle against a higher-level multi-stage execution plan rather than assuming `chainId` alone solves cross-chain orchestration.

## 12. Adapter Authenticity Controls Origin Trust

Test adapters use configurable API origins; production deployments would pin canonical origins. A malicious adapter can request a credential for an attacker origin or fabricate semantic results even when the transport behaves correctly.

### Proposed Solution

Keep discovery/authenticity separate from the capability ABIs, but require clients to combine:

- trusted adapter identity or registry evidence;
- exact origin authorization for each credential;
- callback validation of response provenance and semantic bindings.

No one layer is sufficient alone.

## Recommended Next Sequence

1. Prototype content-addressed descriptor retrieval and authenticity to reduce adapter bytecode.
2. Add arrays, cross-field constraints, JSON schema references, and generic rendering.
3. Prototype atomicity requirements, simulation return assertions, and postcondition queries as extensions.
4. Add adversarial fixtures for malformed JSON, duplicate fields, hostile calldata, secret exfiltration, and side-effecting HTTP.
5. Write a separate external-effect/x402/SIWX design note rather than expanding External Request v0.
6. Revisit the base ABIs only after those experiments produce implementation evidence.

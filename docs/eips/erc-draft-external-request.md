---
title: External HTTP Request Continuations
description: Enables EVM calls to request client-completed HTTP interactions and resume through contract callbacks.
author: Stephan Cilliers (@stephancill)
discussions-to: https://ethereum-magicians.org/t/replace-before-submission
status: Draft
type: Standards Track
category: ERC
created: 2026-08-25
---

## Abstract

This proposal defines a revert-based continuation mechanism through which an EVM call describes one HTTP request, a client supplies locally held string values required by the request, the client executes it, and execution resumes through a contract callback. The callback receives the HTTP status, response headers, raw response body, and opaque continuation data. Recursive continuations permit multi-request resolution without application-specific client logic or disclosure of client-held requirement values to the contract.

## Motivation

EVM contracts cannot directly perform HTTP requests. Applications that depend on indexed data, remote computation, or authenticated APIs therefore require bespoke client integrations even when their control flow is otherwise expressible by a contract.

A common continuation protocol allows a contract to describe the method, URL, headers, body, client-owned requirements, and callback needed to complete an interrupted call. Clients can apply local network, origin, credential, and privacy policies before executing the request. Sensitive requirement values are inserted only into the outbound HTTP request and are not returned to the contract.

This mechanism is useful for external reads and side-effect-free remote computation. It does not provide consensus data, oracle verification, credential discovery, wallet authorization, or safe semantics for durable remote side effects.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### ABI

Implementations MUST use the following ABI exactly:

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

enum RequestLocation {
    HEADER,
    QUERY,
    BODY
}

struct HttpHeader {
    string name;
    string value;
}

struct RequestRequirement {
    RequestLocation location;
    string path;
    string description;
    bool sensitive;
}

struct HttpRequest {
    string url;
    string method;
    HttpHeader[] headers;
    bytes body;
    RequestRequirement[] requirements;
}

enum ResponseBodyEncoding {
    RAW,
    JSON_ABI
}

struct HttpResponse {
    uint16 status;
    HttpHeader[] headers;
    bytes32 rawBodyHash;
    ResponseBodyEncoding bodyEncoding;
    bytes body;
}

enum ResponseTransformKind {
    RAW,
    JSON_ABI
}

enum JsonAbiNodeType {
    TUPLE,
    ARRAY,
    BOOL,
    UINT256_DECIMAL,
    UINT256_HEX,
    INT256_DECIMAL,
    ADDRESS,
    BYTES,
    BYTES32,
    STRING
}

struct JsonAbiNode {
    JsonAbiNodeType nodeType;
    string pointer;
    uint16 childCount;
    uint32 maxItems;
}

struct ResponseTransform {
    ResponseTransformKind kind;
    uint16 statusFrom;
    uint16 statusTo;
    JsonAbiNode[] nodes;
}

error ExternalRequest(
    address sender,
    HttpRequest request,
    ResponseTransform responseTransform,
    bytes4 callbackFunction,
    bytes extraData
);

interface IExternalRequestCallback {
    function externalRequestCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (bytes memory result);
}
```

The ABI values of `RequestLocation.HEADER`, `RequestLocation.QUERY`, and `RequestLocation.BODY` are `0`, `1`, and `2`, respectively. `ResponseBodyEncoding.RAW` is `0` and `ResponseBodyEncoding.JSON_ABI` is `1`. `ResponseTransformKind.RAW` is `0` and `ResponseTransformKind.JSON_ABI` is `1`. `ResponseTransform` and its `JsonAbiNode` tree are defined in [Response Transformation](#response-transformation).

The canonical error signature is:

```text
ExternalRequest(address,(string,string,(string,string)[],bytes,(uint8,string,string,bool)[]),(uint8,uint16,uint16,(uint8,string,uint16,uint32)[]),bytes4,bytes)
```

Its selector is `0x062cdd56`.

The callback interface function is illustrative. A contract MAY use any callback function name and return type provided its function selector accepts `(HttpResponse,bytes)` and its terminal return data is ABI-compatible with the interrupted top-level function.

### Client Processing

A client resolving an EVM call that reverts with `ExternalRequest` MUST:

1. Decode the complete revert payload and reject malformed data or an unknown `RequestLocation` value.
2. Verify that `sender` equals the address called by the current EVM call.
3. Validate the request under this specification and local URL, origin, credential, and network policies.
4. Obtain one Unicode string value for every requirement.
5. Insert requirement values in their declared order.
6. Authorize the completed request before network access.
7. Execute the HTTP request without automatically following redirects.
8. Construct an `HttpResponse` from the received status, headers, and body.
9. Call `sender` using `callbackFunction`, the response, and unchanged `extraData`.
10. Repeat this process if the callback reverts with another valid `ExternalRequest`.

If the initial call or a callback succeeds, its return data MUST become the result of the resolution operation. A revert other than a valid `ExternalRequest` MUST be returned as an error.

A client MUST impose a limit on the total number of external requests resolved for one operation. A conforming client MUST support a limit of at least four and MAY expose a higher configurable limit.

### Request Validation

`url` MUST be an absolute HTTPS URL with a nonempty host. URL user information and fragments are forbidden.

`method` is case-sensitive and MUST match:

```regex
^[A-Z]+$
```

HTTP field names MUST match:

```regex
^[!#$%&'*+.^_`|~0-9A-Za-z-]+$
```

Header names MUST be compared case-insensitively. Header values MUST NOT contain carriage return or line feed characters. `headers` MUST NOT contain duplicate field names.

A `HEADER` requirement path MUST be a valid HTTP field name and MUST NOT target a field already present in `headers`.

Requirements MUST NOT contain duplicate `(location, path)` pairs. Header paths are compared case-insensitively. Query and body paths are compared as exact strings.

Clients MUST reject loopback, link-local, private-network, multicast, unspecified, and cloud-metadata destinations unless local policy explicitly authorizes the exact destination. This policy MUST account for every resolved IP address, DNS rebinding, and the address used for the connection.

### Requirement Values

Every requirement is satisfied by one Unicode string. Credential discovery, storage, and interpretation of `description` are outside this proposal.

`description` is user-facing context. It MUST NOT be treated as a credential identifier or authorization grant.

Before transmitting a requirement marked `sensitive`, the client MUST obtain explicit authorization for the exact URL origin. Authorization for one origin MUST NOT authorize another origin.

Sensitive values MUST NOT be written to logs, diagnostics, callback data, `extraData`, contract calldata, analytics, or persistent caches. A client MAY apply the same protections to requirements not marked sensitive.

### Header Insertion

For a `HEADER` requirement, `path` is the HTTP field name and the supplied string is the complete field value.

The completed field MUST be appended after the fields supplied in `HttpRequest`. A supplied value containing carriage return or line feed characters MUST be rejected.

### Query Insertion

For a `QUERY` requirement, `path` is the query parameter name.

The client MUST parse and modify the URL using the URL Standard's query model. Existing query entries MUST be preserved in order. If an existing entry has a name equal to `path`, the request MUST be rejected.

The client MUST append one `(path, value)` entry using the URL Standard's query serialization. Requirements are applied in declared order.

Clients SHOULD reject sensitive query requirements because URLs are commonly retained by intermediaries and diagnostics.

### JSON Body Insertion

A `BODY` requirement uses JSON insertion only when the normalized media type is `application/json`. Media type matching is case-insensitive and ignores parameters.

The body MUST be valid UTF-8 JSON. `path` MUST be a valid JSON Pointer in the string representation defined by RFC 6901. Pointer tokens decode `~1` to `/` and then `~0` to `~`.

The supplied requirement value is always inserted as a JSON string:

- The empty pointer replaces the complete document.
- Every non-final token MUST identify an existing object member whose value is an object.
- The final token MAY replace an existing object member or create a new member.
- Array traversal and the `-` token are unsupported and MUST be rejected.
- Missing parent objects MUST NOT be created.
- Requirements MUST be applied in declared order.

After all insertions, the client MUST serialize the body as compact UTF-8 JSON. Existing object-member order MUST be preserved, replaced members MUST retain their positions, and newly created members MUST be appended.

### Form Body Insertion

A `BODY` requirement uses form insertion only when the normalized media type is `application/x-www-form-urlencoded`. In this case, `path` is the field name.

The body MUST be parsed as an ordered list using the URL Standard's `application/x-www-form-urlencoded` parser. Existing fields MUST be preserved in order. If an existing field has a name equal to `path`, the request MUST be rejected.

The client MUST append one `(path, value)` field using the URL Standard's form serializer. Requirements are applied in declared order.

### Unsupported Bodies

A `BODY` requirement with an absent, malformed, ambiguous, or unsupported `Content-Type` MUST be rejected. Multiple `Content-Type` fields are invalid. Media type parameters do not affect media type matching.

### HTTP Execution

The completed request MUST use the specified URL, case-sensitive method, headers, and body. An HTTP implementation MAY add fields required by the transport but MUST NOT silently replace a declared field value.

Clients MUST NOT automatically follow redirects. A 3xx response MUST be delivered to the callback like any other HTTP response. Requirement values MUST NOT be propagated to a redirect target.

Clients MUST impose configurable response-header and response-body size limits. They SHOULD also impose connection, TLS, read, and total-operation timeouts.

### HTTP Response

The callback response MUST be encoded as:

```solidity
HttpResponse({
    status: numericStatus,
    headers: headersInReceivedOrder,
    rawBodyHash: keccak256(rawResponseBody),
    bodyEncoding: computedBodyEncoding,
    body: responseBody
})
```

The numeric HTTP status MUST fit in `uint16`. Response headers MUST be supplied in received order. `rawBodyHash` MUST be the `keccak256` digest over the exact raw response body delivered to this continuation step, before any projection. The `body` field MUST contain the raw response bytes after any transfer-coding processing performed by the HTTP stack and before application-specific decoding, unless the declared `ResponseTransform` requires projection (see [Response Transformation](#response-transformation)), in which case it MUST contain the projected ABI-encoded body. `bodyEncoding` MUST equal `ResponseBodyEncoding.RAW` in the first case and `ResponseBodyEncoding.JSON_ABI` in the second.

Non-2xx statuses MUST NOT be treated as transport failures. DNS, TLS, connection, timeout, policy, size-limit, and malformed-response failures MUST NOT invoke the callback.

### Response Transformation

An adapter MAY declare a `ResponseTransform` in the `ExternalRequest` payload to have the client coerce the raw response body into a typed ABI body before the callback. A `ResponseTransform.kind` of `RAW` declares that the raw body MUST be delivered unchanged (`bodyEncoding == RAW`). A kind of `JSON_ABI` declares that the client MUST deliver a strictly coerced ABI-encoded body (`bodyEncoding == JSON_ABI`), unless the numeric status is outside the inclusive `statusFrom..statusTo` range, in which case the raw body MUST be delivered instead (`bodyEncoding == RAW`).

Projection moves JSON decoding and ABI coercion to the client but does not authenticate the HTTP response: a callback MUST still validate the projected values against account binding, provenance, signatures or proofs, chains, assets, amounts, freshness, and replay protection needed by its application.

The `ResponseTransform.nodes` array encodes one complete preorder projection tree. Every `JsonAbiNode` declares its `nodeType`; `pointer`, an RFC 6901 JSON Pointer evaluated relative to the parent node's JSON value (the empty pointer selects that parent value itself); `childCount`, the number of direct children; and `maxItems`, the maximum supported array length, which MUST be nonzero for `ARRAY` and zero for all other node types. Each node resolves the JSON value it selects for the callback ABI value:

- A `TUPLE` node maps its ordered children to the ABI tuple components it represents.
- An `ARRAY` node has exactly one child, the element schema, evaluated against each element of the JSON array. A nonzero `maxItems` MUST cap the array length, and every element MUST match the schema; empties and fixed-size arrays are otherwise unsupported.
- A scalar node coerces the selected JSON value to exactly one ABI primitive: `BOOL`, `UINT256_DECIMAL`, `UINT256_HEX`, `INT256_DECIMAL`, `ADDRESS`, `BYTES`, `BYTES32`, or `STRING`.

Projection MUST fail closed rather than produce defaults: missing JSON fields, `null`, type mismatches, malformed or out-of-range pointers, mismatched child counts, `ARRAY` nodes with other than one child, duplicate object keys, and imprecise numeric representations MUST revert the projection. Integers MUST be converted from their decimal or hexadecimal representation without JavaScript `number` intermediates.

Clients MUST impose their own bounded limits on total node count, tree depth, selected value size, and projected-body size, and MUST reject projections that exceed them. Descriptor and projection data are untrusted; a client MUST NOT allocate unboundedly on their behalf.

### Continuation

Callback calldata MUST be constructed as:

```solidity
abi.encodeWithSelector(callbackFunction, response, extraData)
```

The client MUST call `sender` with this calldata. `extraData` MUST be passed byte-for-byte unchanged for that continuation step.

A callback MAY initiate another request by reverting with `ExternalRequest`. The nested request's `sender` MUST equal the address called for that callback, and its own `extraData` MUST be preserved independently.

A terminal callback's return data MUST be ABI-compatible with the interrupted top-level function. A callback that initiates another request need not return successfully at that stage.

## Rationale

### Revert-Based Signaling

Revert data lets existing function signatures request external resolution without adding alternate entry points or changing declared return types. Clients that do not recognize the custom error observe an ordinary failed call.

The `sender` field prevents a client from treating most errors bubbled from unrelated nested calls as instructions from the top-level contract.

### Concrete Requests and Client-Owned Values

The proposal describes a concrete HTTP request rather than an opaque gateway query. Requirements identify narrow insertion points while values such as credentials or account identifiers remain under client control. A string-only requirement model keeps the ABI small and avoids standardizing credential formats or acquisition workflows.

Requirement values are excluded from callback data because returning them would disclose them through EVM calldata and RPC infrastructure.

### Structured Responses

Returning status, headers, and raw body supports APIs whose application semantics depend on non-2xx statuses, media types, signatures, or binary data. Interpretation and verification remain application-specific callback responsibilities.

### Response Projection

Callbacks often need specific fields from a JSON API response rather than the whole document. Decoding that JSON on chain is expensive because small reads require general-purpose parsers, and it duplicates logic that the client already has. A declarative projection lets a contract describe, in its own revert payload, exactly how the client should coerce a JSON response into a typed ABI tuple, so the callback can `abi.decode` a compact struct directly.

The projection is strictly single-use, bounded, and fails closed: it reduces on chain parsing cost while leaving authenticity and application semantics with the callback. The raw-body commitment and non-projected status range keep every projection verifiable against the bytes the adapter actually declared. Projection is a structural convenience, not a trust mechanism, and does not reduce the callback's validation responsibilities.

### Recursive Callbacks

Callbacks and opaque `extraData` provide continuation state without persistent contract storage. Recursion supports workflows in which one response determines a subsequent request while retaining a uniform client algorithm.

### Redirect Handling

Automatic redirects are excluded because a redirect can change the origin receiving a credential, alter request semantics, or make execution depend on client-specific redirect behavior. Delivering the 3xx response preserves application visibility without silently expanding authority.

### Relationship to [ERC-3668](./eip-3668.md)

[ERC-3668](./eip-3668.md) defines retrieval from contract-selected gateways using URL templates and opaque gateway calldata. Its gateway returns opaque bytes that a callback commonly verifies against on-chain commitments.

This proposal instead carries a concrete HTTP method, headers, body, client-owned insertion requirements, and structured HTTP response. It is intended for application APIs and local client context rather than specifically for proof-bearing gateway retrieval. It neither supersedes nor changes ERC-3668; a contract may use both mechanisms through their distinct error selectors.

### Relationship to [ERC-7412](./eip-7412.md)

[ERC-7412](./eip-7412.md) requests signed oracle data and prepares a multicall that invokes an on-chain verifier before retrying the original operation. That design can write verified data on chain and account for oracle fulfillment fees.

This proposal performs an HTTP request and resumes through a callback. It does not prepend fulfillment transactions, select an oracle network, charge verification fees, write response data on chain, or establish response authenticity. Applications requiring oracle guarantees need independent signatures, proofs, or verifier contracts.

### Remote Side Effects

External resolution can be retried during simulation, estimation, or user-interface refreshes. It is therefore best suited to retrieval and side-effect-free computation. Durable remote effects need a separate protocol covering user confirmation, idempotency, retry behavior, expiry, cost limits, and postconditions.

## Backwards Compatibility

Existing contracts and clients are unaffected.

Calls requiring this proposal fail with an ordinary custom-error revert when used through a client that does not implement it. Supporting clients can recognize the distinct selector without changing handling of successful calls, other reverts, ERC-3668, or ERC-7412.

The ABI is new and does not claim compatibility with earlier experimental variants.

## Test Cases

### Mixed Insertion

Given:

```text
URL:     https://api.example.com/quote?market=eth
Method:  POST
Header:  Content-Type: application/json; charset=utf-8
Body:    {"asset":"ETH","credentials":{}}
```

and these requirements and values:

| Location | Path | Value |
| --- | --- | --- |
| `HEADER` | `Authorization` | `Bearer secret` |
| `QUERY` | `account_id` | `account 1` |
| `BODY` | `/credentials/api~1key` | `key` |

the completed request is:

```text
URL:     https://api.example.com/quote?market=eth&account_id=account+1
Method:  POST
Headers:
  Content-Type: application/json; charset=utf-8
  Authorization: Bearer secret
Body:    {"asset":"ETH","credentials":{"api/key":"key"}}
```

### Form Insertion

Given:

```text
Content-Type: application/x-www-form-urlencoded
Body: asset=ETH
```

and a `BODY` requirement with path `api_key` and value `a secret/value`, the completed body is:

```text
asset=ETH&api_key=a+secret%2Fvalue
```

### JSON Replacement and Ordering

Given:

```json
{"first":1,"nested":{"existing":true}}
```

applying `/nested/new` with value `x`, followed by `/first` with value `one`, produces:

```json
{"first":"one","nested":{"existing":true,"new":"x"}}
```

Applying the empty pointer with value `replacement` instead produces:

```json
"replacement"
```

### Continuation Encoding

For:

```text
callbackFunction = 0x12345678
response.status    = 200
response.headers   = [("Content-Type", "text/plain")]
response.body      = 0x6f6b
extraData          = 0x1122
```

the callback calldata is:

```text
0x12345678 || abi.encode(
    (
        uint16(200),
        [("Content-Type", "text/plain")],
        keccak256(hex"6f6b"),
        uint8(0),        // ResponseBodyEncoding.RAW
        hex"6f6b"
    ),
    hex"1122"
)
```

A callback that succeeds with return data `0xcafe` resolves the original operation to `0xcafe`.

### Projection Round Trip

Given a `ResponseTransform` with `kind == JSON_ABI`, `statusFrom = 200`, `statusTo = 299`, and a preorder tree selecting `id` as a `UINT256_DECIMAL` the body of `{"id": 42, "name": "x"}` under a `TUPLE` root, the client MUST deliver a projected body equal to `abi.encode(uint256(42))` and a `bodyEncoding` of `JSON_ABI`, with `rawBodyHash` equal to the digest of the full raw `{"id": 42, "name": "x"}` bytes. The same transform against a `500` response MUST instead deliver the raw body with `bodyEncoding` of `RAW`.

### Rejection Cases

The following requests are rejected before HTTP execution:

| Input | Reason |
| --- | --- |
| `http://api.example.com/` | Non-HTTPS URL |
| `https://user@api.example.com/` | URL user information |
| `https://api.example.com/#fragment` | URL fragment |
| Method `post` | Invalid method syntax |
| Headers `Authorization` and `authorization` | Duplicate field name |
| Existing query `account_id=x` and a `QUERY` requirement for `account_id` | Conflicting query entry |
| JSON pointer `/missing/key` when `missing` is absent | Missing parent |
| Mismatched `sender` and currently called address | Invalid continuation source |

A received `302` response is passed to the callback without following its `Location` field.

## Reference Implementation

The ABI declaration in the Specification is the contract-side reference. The following pseudocode illustrates the client continuation loop:

```typescript
async function resolveExternalRequest({
  initialCall,
  evmCall,
  resolveRequirement,
  authorizeRequest,
  executeHttp,
  maxRequests = 4,
}) {
  let call = initialCall;

  for (let requestCount = 0; ; requestCount += 1) {
    try {
      return await evmCall(call);
    } catch (error) {
      const external = tryDecodeExternalRequest(extractRevertData(error));

      if (external === undefined) throw error;
      if (requestCount >= maxRequests) throw new Error("request limit exceeded");
      if (external.sender !== call.to) throw new Error("sender mismatch");

      validateRequest(external.request);
      const completed = await completeRequestInDeclaredOrder({
        request: external.request,
        resolveRequirement,
      });

      await authorizeRequest({
        originalRequest: external.request,
        completedRequest: completed.request,
        resolvedRequirements: completed.requirements,
      });

      const response = await executeHttp({
        ...completed.request,
        redirect: "manual",
      });

      call = {
        to: external.sender,
        data:
          external.callbackFunction +
          abiEncode(response, external.extraData).slice(2),
      };
    }
  }
}
```

Request completion in this pseudocode follows the header, query, JSON, and form algorithms defined above. Authorization occurs before network access.

## Security Considerations

### Untrusted Destinations

A contract can cause a supporting client to contact an attacker-controlled host. Clients need server-side request forgery defenses covering URL parsing, all DNS answers, DNS rebinding, the connected peer address, IPv4 and IPv6 special-use ranges, local services, and cloud metadata endpoints. TLS alone does not establish that a destination is appropriate.

### Credential Exfiltration

A malicious or compromised contract can request a credential for an attacker-controlled origin or misleading path. Origin authorization, trusted contract identity, and user review address different parts of this risk and are not substitutes for one another. Requirement descriptions are untrusted display text.

Sensitive query values can leak through browser history, intermediary logs, caches, referrers, and diagnostics. Header insertion is generally preferable for bearer credentials.

### Redirects

Redirects can exfiltrate credentials or change request meaning. HTTP libraries used by resolvers need explicit manual-redirect behavior, including for redirects performed below the application abstraction.

### Untrusted Responses

HTTP responses and adapters are untrusted. Callbacks need to validate all application-relevant signatures, proofs, chains, contract addresses, selectors, recipients, assets, account identifiers, amounts, limits, fees, deadlines, nonces, and replay protections.

Executable calldata returned by an API is particularly dangerous. A callback should decode it, restrict the target and selector, validate every security-relevant field, and canonically re-encode it rather than forwarding arbitrary bytes.

### Callback Invocation

Callback functions are externally callable and cannot infer that their arguments came from the client continuation process. Authorization and input checks performed by the interrupted function need to be repeated or cryptographically bound through `extraData`. Continuation data should include the original parameters needed to establish response relevance.

Contracts should not blindly bubble `ExternalRequest` errors from nested calls. An initiating contract can catch and wrap a nested continuation so `sender` and callback state describe an invocation the client can resume.

### Privacy

HTTP requests can reveal a user's IP address, timing, selected application, and potentially wallet-linked activity. Clients can mitigate this through consent, origin policy, proxies, or disabling external resolution for privacy-sensitive operations.

Response bodies can themselves contain private or bearer-secret data. This ABI does not label response sensitivity, so clients and applications need out-of-band policy before exposing, persisting, or forwarding responses.

### Denial of Service

Contracts can request large responses, slow endpoints, recursive continuations, expensive parsing, or many requirement resolutions. Implementations need bounded request depth, response-header and body limits, timeouts, and cancellation.

JSON and ABI decoders need to reject malformed, deeply nested, or resource-exhausting inputs safely. A declared projection is untrusted and can itself be huge, deep, or self-referential: clients MUST enforce their own node-count, depth, value-size, and projected-body limits before parsing or coercing a response, and MUST fail closed on any projection that exceeds them.

### Remote Side Effects

Repeated simulation or resolution can execute the same HTTP request more than once. Endpoints that create orders, invoices, messages, or other durable state can therefore cause unintended duplicate effects. Such operations are unsafe without explicit effect classification, idempotency, confirmation, and retry semantics outside this proposal.

### Non-Determinism

HTTP responses are not consensus inputs and can vary by client, time, region, identity, or network path. Any result later used in a transaction needs application-specific validation that binds it to the intended operation and relevant on-chain state.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).

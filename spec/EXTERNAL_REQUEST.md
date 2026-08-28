# External Request v0

## Status

This document is an experimental, non-final specification. The ABI may change based on reference implementations and interoperability testing.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as described by RFC 2119 and RFC 8174.

## Abstract

External Request is a revert-based continuation mechanism through which an EVM call describes one HTTP request, a client completes and executes that request, and the client resumes execution through a callback.

The experimental ABI is defined by `contracts/IExternalRequest.sol`.

## Processing Model

When an EVM call reverts with `ExternalRequest`, a compliant client MUST:

1. Decode the complete revert payload.
2. Verify that `sender` equals the address called by the current EVM call.
3. Validate the request against local URL, origin, credential, and network policies.
4. Obtain a string value for every request requirement.
5. Construct the HTTP request according to this specification.
6. Execute the HTTP request without automatically following redirects.
7. Encode the HTTP response and unchanged `extraData` for `callbackFunction`.
8. call `sender` with the resulting callback calldata.
9. Repeat when the callback reverts with another valid `ExternalRequest`.

A client MUST impose a recursion limit. A compliant v0 client MUST support a limit of at least four requests and MAY support a higher configurable limit.

## Request Validation

- `url` MUST be an absolute HTTPS URL.
- User information in URLs is forbidden.
- URL fragments are forbidden.
- Methods are case-sensitive protocol values and MUST match `^[A-Z]+$` in v0.
- Header names MUST be valid HTTP field names and compared case-insensitively.
- The request MUST NOT contain duplicate header names.
- A requirement MUST NOT target a header already present in `headers`.
- Requirements MUST NOT contain duplicate `(location, path)` pairs.

Clients MUST reject loopback, link-local, private-network, multicast, unspecified, and cloud-metadata destinations unless an explicit local policy authorizes that exact destination. This policy MUST account for every resolved IP address and DNS rebinding.

## Requirement Values

Every v0 requirement is satisfied with one Unicode string. The string is inserted according to the requirement location. Credential discovery and storage are outside this specification.

A client MUST obtain explicit origin authorization before sending a sensitive value. Authorization for one origin MUST NOT authorize another origin.

Sensitive values MUST NOT be written to logs, diagnostics, callback data, `extraData`, contract calldata, or persistent caches.

## Header Insertion

For `HEADER`, `path` is an HTTP field name. The client inserts the supplied string as the complete field value. Values containing CR or LF MUST be rejected.

## Query Insertion

For `QUERY`, `path` is a query parameter name. The client appends one query entry using the URL Standard's query serialization. Existing query entries are preserved in order. A requirement whose name already exists in the URL MUST be rejected.

Clients SHOULD reject sensitive query requirements because URLs are frequently retained by infrastructure.

## JSON Body Insertion

JSON insertion applies only when the normalized media type is `application/json`. `path` MUST be a valid RFC 6901 JSON Pointer.

The supplied requirement value is always inserted as a JSON string in v0.

- The empty pointer replaces the complete document with the supplied string.
- Every non-final pointer token MUST already identify an object.
- The final token MAY replace an existing object member or create a new object member.
- Array traversal and the `-` token are unsupported in v0.
- Missing parent objects MUST NOT be created implicitly.
- Requirements are applied in their declared order.

The output body MUST be serialized as UTF-8 JSON. Clients MUST use deterministic compact serialization for interoperability tests; object member order from the parsed input is preserved and newly created members are appended.

## Form Body Insertion

Form insertion applies only when the normalized media type is `application/x-www-form-urlencoded`. `path` is the field name. Existing fields are preserved in order. A requirement whose field already exists MUST be rejected. The new field is appended using the URL Standard's form serialization.

## Unsupported Bodies

A BODY requirement with an absent, ambiguous, or unsupported `Content-Type` MUST be rejected. Media type parameters do not affect media type matching. Multiple `Content-Type` headers are invalid.

## HTTP Response

The callback receives an ABI-encoded `HttpResponse` containing:

- the numeric HTTP status;
- response headers in received order;
- `rawBodyHash`, a `keccak256` commitment over the exact raw response body;
- `bodyEncoding`, whether `body` carries the raw bytes or a projected ABI body;
- the response body.

Clients MUST NOT treat non-2xx status codes as transport failures. They are delivered to the callback for application-level interpretation. DNS, TLS, connection, timeout, policy, size-limit, and malformed-response failures MUST NOT invoke the callback.

Clients MUST impose configurable response-body and header-size limits.

## Response Transformation

An adapter MAY declare a `ResponseTransform` in the `ExternalRequest` payload. Raw responses are recommended for opaque application data; projection is recommended when a callback must decode or validate response fields.

`ResponseTransform.kind` MUST be `RAW` or `JSON_ABI`:

- With `RAW`, the client MUST deliver the raw response body unchanged and set `bodyEncoding == RAW`.
- With `JSON_ABI`, the client MUST deliver a strictly coerced ABI-encoded body and set `bodyEncoding == JSON_ABI`, unless the status is outside `statusFrom..statusTo`, in which case the raw body is delivered.

### Projection Tree

`JSON_ABI` nodes form one complete preorder tree. Each `JsonAbiNode` declares a node type, an RFC 6901 JSON Pointer relative to the parent node's JSON value, a direct child count, and an array maximum.

- `TUPLE` nodes map their ordered children to ABI tuple components.
- `ARRAY` nodes have exactly one child, which is the element schema evaluated against each element of the JSON array. A non-zero `maxItems` MUST cap array length; every element MUST match.
- Scalar nodes coerce the selected JSON value to one ABI primitive: `bool`, decimal or hexadecimal `uint256`, decimal `int256`, `address`, `bytes`, `bytes32`, or `string`.
- Missing JSON fields, `null`, type mismatches, and malformed pointers MUST fail the projection rather than produce defaults.
- Duplicate object keys and imprecise numeric representations MUST be rejected. Integers MUST be converted without JavaScript `number` intermediates.
- Clients MUST impose their own node count, tree depth, total value, and projected-body limits and reject projections that exceed them.

The ordered tree defines the single ABI value encoded into `HttpResponse.body`. The callback MUST decode `body` using exactly that projected shape; `rawBodyHash` documents which raw response the projection came from. Projection moves JSON decoding and coercion to the client but does not authenticate the HTTP response: callbacks MUST still validate account binding, provenance, and semantics themselves.

## Redirects

Clients MUST NOT automatically follow redirects in v0. A 3xx response is delivered to the callback like any other HTTP response. In particular, sensitive values MUST NOT be propagated to a redirect target.

## Callback

Callback calldata is constructed as:

```solidity
abi.encodeWithSelector(callbackFunction, response, extraData)
```

where `response` has Solidity type `HttpResponse` and `extraData` is passed byte-for-byte unchanged.

When a callback completes successfully, its return data becomes the result of the original client resolution operation. The contract initiating External Request MUST therefore ensure that every terminal callback returns data ABI-compatible with the interrupted top-level function. A callback that initiates another External Request need not return successfully at that stage.

## Security Considerations

Resolvers and callback response data are untrusted. Clients MUST enforce network and origin policies before executing HTTP requests. Callbacks MUST validate response signatures, proofs, asset identifiers, account identifiers, amounts, deadlines, and replay protections required by their application.

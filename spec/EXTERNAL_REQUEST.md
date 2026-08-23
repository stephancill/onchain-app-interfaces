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
- the raw response body.

Clients MUST NOT treat non-2xx status codes as transport failures. They are delivered to the callback for application-level interpretation. DNS, TLS, connection, timeout, policy, size-limit, and malformed-response failures MUST NOT invoke the callback.

Clients MUST impose configurable response-body and header-size limits.

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

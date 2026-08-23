# Application Queries v0

## Status

This document is an experimental, non-final specification. The ABI may change based on reference implementations and real application adapters.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as described by RFC 2119 and RFC 8174.

## Abstract

Application Queries exposes discoverable, application-level semantic reads. A query may aggregate onchain state, indexed history, external services, or private application data before returning one encoded semantic result.

Queries describe what an application knows. Application Actions separately describe what a user can do.

## Interface

The experimental interface is defined by `contracts/IApplicationQueries.sol`.

Application Queries and Application Actions are separate optional capabilities. An application adapter MAY implement either or both.

## Query Discovery

`queries()` returns the query identifiers currently exposed by the adapter. Query identifiers are adapter-defined in v0. Clients MUST NOT assume a global taxonomy.

An adapter SHOULD expose semantic aggregation, normalization, application-specific computation, indexed data, or external data. It SHOULD NOT create trivial wrappers for every low-level contract getter.

## Descriptors

`queryDescriptor(queryId)` returns adapter-defined descriptor bytes. A query descriptor describes both the query input schema and result schema.

The base interface does not freeze descriptor serialization. This repository currently evaluates the shared experimental JSON profile in `spec/DESCRIPTORS.md` for query inputs, outputs, provenance, and sensitivity.

## Query Execution

`query(queryId, parameters)` returns one encoded semantic result.

- `parameters` use the input encoding declared by the query descriptor.
- `result` uses the output encoding declared by the query descriptor.
- Account identity has no distinguished ABI argument. A query that requires an account MUST include it in `parameters`.
- A query MAY continue through the External Request specification in `spec/EXTERNAL_REQUEST.md`.
- A client MUST handle External Request identically whether it originates from `query()` or `prepare()`.
- A terminal query callback MUST return data ABI-compatible with `query()` so the client can decode the final result using the query interface and descriptor.

## Freshness

v0 does not define a generic query-result wrapper. A query whose result has freshness or expiry semantics MUST include those fields in its semantic result and descriptor.

## Security Considerations

All External Request security requirements apply to queries. Query results may themselves contain sensitive user data. A client SHOULD apply policy before logging, caching, persisting, or exposing query results to another processing or reasoning system.

Query callbacks MUST validate external responses according to application requirements, including account binding, data provenance, signatures or proofs, freshness, size bounds, and replay protection.

## Open Questions

- Shared query/action descriptor serialization and semantic types.
- Canonical query identifiers.
- Sensitive-result metadata and handling.
- Query caching and common freshness semantics.
- Application-adapter discovery and authenticity.

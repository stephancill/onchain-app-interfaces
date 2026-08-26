# Application Descriptor Prototype v0.1

## Status

This document defines an experimental descriptor profile used to evaluate Application Queries and Application Actions. It is not a frozen standard.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as described by RFC 2119 and RFC 8174.

## Purpose

A descriptor lets a generic client encode semantic parameters, decode semantic query results, present constraints and effects, and apply provenance or sensitivity policy without adapter-specific code.

Both `queryDescriptor()` and `actionDescriptor()` return UTF-8 JSON bytes in this prototype.

## Envelope

Every descriptor contains:

```json
{
  "version": "0.1",
  "kind": "query",
  "name": "example.query",
  "inputs": {
    "encoding": "abi",
    "fields": []
  },
  "output": {
    "encoding": "abi",
    "fields": []
  }
}
```

- `version` MUST equal `0.1`.
- `kind` MUST be `query` or `action`.
- `name` identifies the adapter-defined semantic capability.
- `inputs.encoding` MUST be `abi` in v0.1.
- `inputs.fields` describes the actual top-level ABI parameters encoded into `bytes parameters`.
- Query output MUST use either ABI fields or JSON fields (see JSON Outputs).
- Action output MUST be `{ "encoding": "preparedAction" }`.

## Fields

An ABI field contains:

- `name`: parameter or component name;
- `abiType`: a supported scalar ABI type, `tuple`, or its one-dimensional dynamic-array form `T[]` or `tuple[]`;
- `components`: required when `abiType` is `tuple` or `tuple[]` and forbidden otherwise;
- `semanticType`: optional application-level meaning;
- `minimum` and `maximum`: optional decimal integer constraints;
- `minLength`, `maxLength`, and `pattern`: optional string constraints;
- `minItems` and `maxItems`: optional nonnegative integer array-length constraints;
- `assetField`: optional reference to the field identifying a token;
- `contentType`: optional media type for byte strings;
- `sensitivity`: optional `public`, `private`, or `bearer-secret` label;
- `enumValues`: optional mapping from semantic labels to integer values.

v0.1 supports the ABI types exercised by the reference adapters: addresses, booleans, strings, bytes, fixed bytes, integers, and nested tuples. Each supported scalar type and `tuple` MAY use a one-dimensional dynamic-array ABI type ending in `[]`. Fixed-length arrays, multidimensional arrays, and arrays whose element type is itself an array MUST NOT be used.

`minItems` and `maxItems` MAY appear only on array fields. Their values MUST be nonnegative integers, and `minItems` MUST NOT exceed `maxItems`. A client MUST reject a non-array input value for an array field, MUST enforce these bounds before encoding, and MUST normalize and validate every array element according to the element descriptor. A client MUST also enforce these bounds recursively on decoded output arrays without applying input normalization to decoded scalar values. When decoding `tuple[]`, a client MUST recursively represent each tuple element using its component names.

Clients MUST treat `pattern` as a profile-defined constraint rather than execute arbitrary regular expressions from untrusted descriptors. The reference client supports only the bounded ASCII slug patterns used by the prototype adapters.

Struct parameters MUST be represented as one top-level `tuple` field. Clients MUST NOT flatten a tuple because dynamic component offsets would change.

## JSON Outputs

A query descriptor MAY declare a JSON output:

```json
{
  "output": {
    "encoding": "json",
    "fields": [
      {
        "name": "positions",
        "abiType": "tuple[]",
        "maxItems": 64,
        "path": "positions[]",
        "components": [
          {
            "name": "trader",
            "abiType": "address",
            "semanticType": "account",
            "equalsInput": "account"
          }
        ]
      }
    ]
  }
}
```

A JSON output means the adapter's callback returns the raw response body bytes, and the client derives semantic values by evaluating the output field tree against the decoded UTF-8 JSON document. The adapter remains authoritative for transport-level validation (status code, size bounds, and media type); structural and value-level validation happens in the client according to the descriptor.

In addition to the common field properties, JSON output fields MAY contain:

- `path`: a dot-separated selection path evaluated against the parent node. Each segment MUST match `[A-Za-z_][A-Za-z0-9_-]*` optionally followed by `[]`. At most one segment in a path MAY end with `[]`.
- `equalsInput`: the name of a top-level input field. A client MUST reject the result unless every extracted value of this field equals that input parameter (addresses compared case-insensitively).

Selection rules:

- For an array field, exactly one path segment MUST end with `[]`; the remaining segments select the array, and each element becomes the parent node for component evaluation. When `path` is absent it defaults to the field name followed by `[]`.
- For tuple and scalar fields, the path MUST NOT contain `[]`. When `path` is absent it defaults to the field name.
- Tuple components are evaluated relative to their containing object.
- Array constraints (`minItems`, `maxItems`) MUST be enforced on extracted arrays before element evaluation.

A client MUST fail when a selected key is missing, a selected node has the wrong shape for its field type, or any `equalsInput` binding is violated. Clients MUST NOT fall back to partial results.

Because JSON outputs are validated client-side rather than by adapter contract code, generic clients SHOULD treat such results as origin-authenticated (TLS plus configured origin) but not contract-verified. Descriptors SHOULD use `equalsInput` bindings wherever the semantic result depends on caller identity.

## Provenance

A query descriptor MAY include:

```json
{
  "provenance": {
    "type": "onchain"
  }
}
```

or:

```json
{
  "provenance": {
    "type": "configured-origin"
  }
}
```

Provenance describes where semantic data originates; it does not itself establish trust.

## Effects

An action descriptor MAY include an `effects` array. v0.1 records explanatory effect metadata but does not use it to authorize execution.

```json
{
  "effects": [
    {
      "type": "decrease",
      "assetField": "parameters.tokenIn",
      "amountField": "parameters.amountIn"
    }
  ]
}
```

## Execution

An action MAY declare an experimental execution policy:

```json
{
  "execution": {
    "atomicity": "atomic-required"
  }
}
```

The other v0.1 value is `sequential-allowed`. This metadata records implementation findings but does not modify `PreparedAction` yet.

## Client Requirements

A client MUST validate the complete descriptor before using it. Unknown versions, kinds, encodings, ABI types, malformed constraints, and duplicate field names MUST fail rather than fall back.

A generic client MUST apply descriptor constraints before encoding parameters. Adapter validation remains authoritative and MUST independently reject invalid parameters.

Sensitive result fields MUST be handled according to local client policy. Descriptors never authorize disclosure by themselves.

## Deferred

- Canonical JSON serialization and descriptor hashing.
- Content-addressed or URI-based descriptors.
- Richer algebraic schemas.
- Cross-field and state-dependent constraints.
- Standard effect and warning taxonomies.
- Localization and user-facing rendering.
- Formal JSON Schema compatibility.

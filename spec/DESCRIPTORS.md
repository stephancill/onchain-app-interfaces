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
- Query output MUST use ABI fields.
- Action output MUST be `{ "encoding": "preparedAction" }`.

## Fields

An ABI field contains:

- `name`: parameter or component name;
- `abiType`: a supported ABI type or `tuple`;
- `components`: required when `abiType` is `tuple`;
- `semanticType`: optional application-level meaning;
- `minimum` and `maximum`: optional decimal integer constraints;
- `minLength`, `maxLength`, and `pattern`: optional string constraints;
- `assetField`: optional reference to the field identifying a token;
- `contentType`: optional media type for byte strings;
- `sensitivity`: optional `public`, `private`, or `bearer-secret` label;
- `enumValues`: optional mapping from semantic labels to integer values.

v0.1 supports the ABI types exercised by the reference adapters: addresses, booleans, strings, bytes, fixed bytes, integers, nested tuples, and dynamic arrays of tuples and scalars using `[]` suffixes (for example `tuple[]` or `uint256[]`). Fixed-size arrays are deferred.

Clients MUST treat `pattern` as a profile-defined constraint rather than execute arbitrary regular expressions from untrusted descriptors. The reference client supports only the bounded ASCII slug patterns used by the prototype adapters.

Struct parameters MUST be represented as one top-level `tuple` field. Clients MUST NOT flatten a tuple because dynamic component offsets would change.

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
- Fixed-size arrays and richer algebraic schemas.
- Cross-field and state-dependent constraints.
- Standard effect and warning taxonomies.
- Localization and user-facing rendering.
- Formal JSON Schema compatibility.

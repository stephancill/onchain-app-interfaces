---
title: Application Query and Action Interfaces
description: Defines discovery of semantic application queries and preparation of semantic actions as EVM calls.
author: Stephan Cilliers (@stephancill)
discussions-to: https://ethereum-magicians.org/t/replace-before-submission
status: Draft
type: Standards Track
category: ERC
created: 2026-08-25
---

## Abstract

This proposal defines separate optional contract interfaces for application-level queries and actions. Queries return encoded semantic application data. Actions compile semantic parameters for an explicit account into an ordered bundle of EVM calls with an optional expiration time. Both capabilities use implementation-defined descriptors so clients can determine parameter and result encodings without adding one contract function for every application operation.

## Motivation

Contract ABIs expose low-level functions and storage-oriented reads, while users and applications reason about higher-level operations and information. A lending application, for example, may need to aggregate positions across markets before preparing an approval and supply operation. A trading application may need to normalize pool state, calculate a quote, and construct router calldata.

This application-level knowledge commonly exists only in application-specific frontends and services. Generic clients therefore cannot discover meaningful reads, construct semantic inputs, decode aggregate results, or prepare transactions without reproducing each application's integration logic.

A small common ABI allows an adapter to expose what an application knows separately from what a user can do. Adapters may implement either capability or both, and existing immutable protocols can be supported by separate adapter contracts.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Terminology

An **adapter** is a contract implementing one or both interfaces in this proposal.

A **query** is an application-level semantic read. It may aggregate or normalize contract state, indexed history, external data, or application-specific computation.

An **action** is an application-level operation that can be prepared as one or more EVM calls. Preparation does not execute or authorize those calls.

A **descriptor** is an encoded document that determines how a capability's semantic parameters and, for queries, semantic result are encoded.

### Application Queries Interface

Adapters exposing queries MUST implement this interface exactly:

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

interface IApplicationQueries {
    function queries() external view returns (bytes32[] memory queryIds);

    function queryDescriptor(bytes32 queryId) external view returns (bytes memory descriptor);

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory result);
}
```

### Application Actions Interface

Adapters exposing actions MUST implement these structures and this interface exactly:

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

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
    function actions() external view returns (bytes32[] memory actionIds);

    function actionDescriptor(bytes32 actionId) external view returns (bytes memory descriptor);

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory preparedAction);
}
```

### Capability Identifiers

Query and action identifiers are opaque `bytes32` values scoped to the adapter that returns them. Implementations MAY derive identifiers from names, hashes, registries, or another local scheme.

Clients MUST NOT assume a global identifier taxonomy. Equal identifiers returned by different adapters MUST NOT be assumed to have equal semantics or encodings. A query identifier and an action identifier returned by the same adapter are also in separate namespaces.

`queries()` MUST return every query identifier currently exposed by the adapter and MUST NOT return duplicates. `actions()` MUST return every action identifier currently exposed by the adapter and MUST NOT return duplicates. Array order has no semantic meaning.

For each identifier returned at a given block, the corresponding descriptor function and execution or preparation function MUST recognize that identifier when evaluated against the same block. Descriptor and execution functions MUST revert for unrecognized identifiers.

Adapters SHOULD expose capabilities that aggregate, normalize, or interpret application state. They SHOULD NOT create trivial semantic wrappers for every low-level contract function or getter.

### Descriptors

Descriptor serialization is implementation-defined by this proposal. A descriptor MUST be self-describing or identify a separately specified descriptor profile.

A query descriptor MUST unambiguously determine:

1. The encoding of `parameters` accepted by `query`.
2. The encoding of `result` returned by `query`.

An action descriptor MUST unambiguously determine the encoding of `parameters` accepted by `prepare`.

Descriptors MAY additionally define field names, semantic types, constraints, provenance, freshness, sensitivity, effects, warnings, or execution-policy metadata.

A client that does not understand the complete descriptor format or identified profile MUST treat semantic invocation as unsupported. It MUST NOT guess an encoding from an identifier, a partial descriptor, or adapter bytecode.

At a given block, a descriptor MUST describe the encoding accepted and returned by its capability at that block. Adapters MUST independently validate parameters and MUST NOT rely on client-side descriptor validation.

Descriptor metadata does not authorize a query, disclose data, or execute prepared calls.

### Query Execution

`query(queryId, parameters)` MUST execute the identified semantic read. `parameters` MUST use the encoding determined by the query descriptor, and `result` MUST use the result encoding determined by that descriptor.

Account identity has no distinguished query argument. A query requiring an account or another identity MUST include it in `parameters` and describe it in the descriptor.

This proposal does not define a generic query-result envelope. A query whose result has observation-time, block, freshness, or expiry semantics MUST include those values in its semantic result and descriptor.

A query MAY use a separately specified revert-based continuation protocol. A client MUST NOT interpret an arbitrary revert as a successful query result. A terminal continuation callback MUST return data ABI-compatible with the `bytes result` return value of `query`, and the decoded result MUST use the encoding determined by the query descriptor.

### Action Preparation

`prepare(actionId, account, parameters)` MUST prepare the identified action for the explicitly supplied `account`. The adapter MUST NOT infer that account from `msg.sender`. The supplied account does not prove control of the account and does not authorize execution.

`parameters` MUST use the encoding determined by the action descriptor.

Each `Call` specifies the `target`, native-currency `value`, and calldata `data` for one EVM call. Calls MUST be returned in their intended execution order. A client that executes them MUST preserve that order.

`validUntil` is an inclusive Unix timestamp. When it is nonzero, a client MUST NOT execute the prepared calls at a timestamp greater than `validUntil` without preparing the action again. A value of zero means only that the adapter declares no time-based expiration; it does not guarantee validity under changing state.

Preparation MAY use a separately specified revert-based continuation protocol. A terminal continuation callback MUST return data ABI-compatible with the `PreparedAction` return value of `prepare`.

### Execution Scope

This proposal does not define transaction submission, authorization, signatures, simulation, gas estimation, batching, receipt tracking, or execution.

A client MUST apply its normal review and authorization policy before executing returned calls. A successful `prepare` call and descriptor metadata MUST NOT be treated as authorization.

Call order specifies relative order only. It MUST NOT be interpreted as requiring atomic or contiguous execution, and it MUST NOT be interpreted as permitting partial execution. This interface contains no field from which either policy can be inferred.

A client MUST NOT infer application-level success solely from the absence of an EVM revert. A target may report business failure through successful return data, and this proposal does not define return-value assertions, simulation requirements, or postconditions.

Adapter discovery, adapter authenticity, and cross-chain execution plans are outside the scope of this proposal.

### Interface Selectors

The Application Queries function selectors are:

| Signature | Selector |
| --- | --- |
| `queries()` | `0x3e66eca0` |
| `queryDescriptor(bytes32)` | `0x49b7d2ea` |
| `query(bytes32,bytes)` | `0xd33170ce` |

Their XOR is `0xa4e04e84`.

The Application Actions function selectors are:

| Signature | Selector |
| --- | --- |
| `actions()` | `0xf99e36bc` |
| `actionDescriptor(bytes32)` | `0xafef12a0` |
| `prepare(bytes32,address,bytes)` | `0xb7581d9d` |

Their XOR is `0xe1293981`.

### Client Procedure

A generic query client SHOULD:

1. Call `queries()`.
2. Retrieve and fully validate `queryDescriptor(queryId)` for a selected query.
3. Encode semantic inputs according to that descriptor.
4. Call `query(queryId, parameters)`, resolving only supported continuation protocols.
5. Decode the semantic result according to the same descriptor.

A generic action client SHOULD:

1. Call `actions()`.
2. Retrieve and fully validate `actionDescriptor(actionId)` for a selected action.
3. Encode semantic inputs according to that descriptor.
4. Call `prepare(actionId, account, parameters)`, resolving only supported continuation protocols.
5. Check `validUntil`, inspect or simulate the calls, and apply local authorization policy before execution.

When snapshot consistency matters, clients SHOULD perform discovery, descriptor retrieval, and query or preparation calls against a fixed block.

## Rationale

### Separate Optional Interfaces

Queries describe what an application knows, while actions describe what a user can do. Keeping them separate lets analytics adapters expose only reads, transaction builders expose only actions, and complete application adapters expose both. It also avoids forcing query-only clients to implement action structures or execution policy.

### Adapter-Scoped Identifiers

A global taxonomy would require agreement on names, versions, schemas, and semantics before applications could experiment. Adapter-scoped identifiers avoid premature coordination, at the cost of preventing clients from inferring semantic equivalence from identifier equality alone.

### Implementation-Defined Descriptors

Freezing a schema language together with the ABI would couple stable discovery and dispatch functions to a descriptor design that still needs implementation experience. Opaque descriptor bytes permit JSON, compact binary formats, content-addressed documents, or future standardized profiles without changing these interfaces.

This provides bounded interoperability. Clients share one discovery and invocation ABI, and a client supporting a descriptor profile can generically use every adapter implementing that profile. Adapters using unrelated profiles remain ABI-compatible but are not automatically semantically interoperable.

[ERC-7730](./eip-7730.md) also enriches encoded EVM data with semantic and display information. It focuses on data presented for signing, while these descriptors additionally need to construct query and action parameters and decode query results.

### Generic Byte Envelopes

Using `bytes` avoids adding one Solidity method for each application capability and supports static or dynamic ABI tuples as well as other descriptor-defined encodings. The outer ABI remains stable as an application's semantic capabilities evolve.

### Explicit Action Account

Preparation commonly occurs through `eth_call`, where the caller may be an RPC provider, wallet backend, or simulator rather than the account that will authorize execution. An explicit account allows preparation to inspect balances, allowances, positions, and account capabilities without relying on `msg.sender`.

Queries have no equivalent distinguished account because many queries are not account-specific and others may involve more than one identity.

### Preparation Rather Than Execution

Returning calls keeps semantic compilation independent from wallets, account types, and transaction formats. [EIP-5792](./eip-5792.md) can transport ordered calls and independently express an atomicity requirement, but a `PreparedAction` does not determine the value of that requirement.

The minimal `Call` omits chain identifiers, gas limits, return assertions, and postconditions. Those fields either belong to execution policy or require evidence from multi-stage and cross-chain implementations before standardization.

### External Continuations

Queries and preparation sometimes require indexed or external data. Keeping continuation transport separate allows entirely on-chain adapters to return directly and lets clients choose which continuation standards and security policies they support.

### Interface Detection

This proposal does not require [ERC-165](./eip-165.md). Adapters that separately implement ERC-165 can advertise the selector XORs listed in the Specification as interface identifiers.

## Backwards Compatibility

This proposal is additive and changes no existing contract, transaction, or client behavior. Existing contracts can implement either interface alongside other interfaces. Unsupported calls fail in the ordinary way.

The ABIs are new and do not claim compatibility with earlier experimental variants. Implementers need to account for accidental function-selector collisions when adding them to existing contracts.

## Test Cases

### Query Round Trip

Assume an adapter defines `QUERY_ID = keccak256("example.double")` and returns a descriptor declaring one ABI-encoded `uint256` input and one ABI-encoded `uint256` output.

For `query(QUERY_ID, abi.encode(uint256(21)))`, the expected semantic result is `abi.encode(uint256(42))`:

```text
parameters:
0x0000000000000000000000000000000000000000000000000000000000000015

result:
0x000000000000000000000000000000000000000000000000000000000000002a
```

An unknown identifier, malformed parameter encoding, or descriptor-invalid value causes a revert.

### Action Preparation

Assume an adapter exposes an action whose descriptor declares one ABI-encoded `uint256 amount`. Preparing amount `7` for account `0x0000000000000000000000000000000000000A11` returns:

```solidity
PreparedAction({
    calls: [
        Call({
            target: address(0x101),
            value: 0,
            data: abi.encodeWithSelector(
                bytes4(0x095ea7b3),
                address(0x202),
                uint256(7)
            )
        }),
        Call({
            target: address(0x202),
            value: 0,
            data: abi.encodeWithSelector(
                bytes4(0x11223344),
                address(0xA11),
                uint256(7)
            )
        })
    ],
    validUntil: 1700000100
})
```

The explicit account is encoded regardless of the caller of `prepare`, and reversing the calls changes the prepared action.

At timestamp `1700000100`, the result passes the inclusive time check. At `1700000101`, the client prepares again. A zero `validUntil` does not expire based on time alone.

### Descriptor Coherence

For every identifier returned by discovery at one block:

- its descriptor function recognizes the identifier;
- valid descriptor-derived parameters are accepted;
- query results decode according to the query descriptor;
- malformed encodings and unrecognized identifiers revert.

No atomicity policy, return assertion, or postcondition can be decoded from the base `PreparedAction` representation.

## Reference Implementation

The interfaces in the Specification are the normative contract-side reference. A minimal combined adapter dispatches identifiers and keeps application-specific encoding within descriptor-selected branches:

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

contract ExampleApplicationAdapter is IApplicationQueries, IApplicationActions {
    bytes32 internal constant DOUBLE = keccak256("example.double");
    bytes32 internal constant SEND = keccak256("example.send");

    error UnknownCapability(bytes32 id);

    function queries() external pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = DOUBLE;
    }

    function queryDescriptor(bytes32 id) external pure returns (bytes memory) {
        if (id != DOUBLE) revert UnknownCapability(id);
        return bytes("abi:uint256->uint256");
    }

    function query(bytes32 id, bytes calldata parameters) external pure returns (bytes memory) {
        if (id != DOUBLE) revert UnknownCapability(id);
        return abi.encode(abi.decode(parameters, (uint256)) * 2);
    }

    function actions() external pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = SEND;
    }

    function actionDescriptor(bytes32 id) external pure returns (bytes memory) {
        if (id != SEND) revert UnknownCapability(id);
        return bytes("abi:address,uint256->preparedAction");
    }

    function prepare(bytes32 id, address, bytes calldata parameters)
        external
        pure
        returns (PreparedAction memory prepared)
    {
        if (id != SEND) revert UnknownCapability(id);
        (address target, uint256 value) = abi.decode(parameters, (address, uint256));
        prepared.calls = new Call[](1);
        prepared.calls[0] = Call({target: target, value: value, data: ""});
    }
}
```

The descriptor strings in this example are illustrative and do not define a descriptor profile.

## Security Considerations

Adapters, descriptors, query results, and prepared calls are untrusted. Clients should authenticate the adapter they intend to use and should not treat semantic claims in a descriptor as proof that the adapter represents a particular application.

Descriptor parsers should fail closed on unknown versions, encodings, malformed types, duplicate fields, excessive nesting, oversized documents, and executable schema features. Adapter-side parameter validation remains necessary even when clients validate descriptors.

Queries and their results can reveal account activity, positions, history, or bearer-secret data through RPC providers, logs, caches, analytics, or automated processing systems. Clients need local disclosure and persistence policy; sensitivity metadata does not itself authorize disclosure.

Prepared calls can transfer native currency, approve token spending, or invoke arbitrary targets. Clients need to inspect destinations, selectors, recipients, assets, amounts, allowances, deadlines, and native value before authorization. Calldata derived from external responses should be decoded and validated rather than forwarded opaquely.

Expiration addresses only time-based validity declared by the adapter. State changes, reorganizations, price movement, nonce changes, or consumed orders can invalidate calls earlier.

Sequential execution can leave effects from earlier calls when a later call fails. Conversely, the interface does not grant permission to execute calls separately. Clients need independent execution policy because the base representation carries no atomicity guarantee.

An EVM call can succeed while returning an application-level error code. Transaction status alone is therefore insufficient evidence that the semantic action succeeded. Integrations can use simulation assertions and postcondition queries outside this interface.

The explicit action account prevents dependence on `msg.sender` during preparation but does not prove account ownership. Authorization remains an execution-layer responsibility.

External continuation callbacks need to bind responses to the intended query or action parameters and validate provenance, signatures or proofs, account identifiers, chains, assets, amounts, freshness, size, and replay protection according to application requirements.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).

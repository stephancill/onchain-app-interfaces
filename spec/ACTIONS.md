# Application Actions v0

## Status

This document is an experimental, non-final specification. The ABI may change based on reference implementations and real protocol adapters.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as described by RFC 2119 and RFC 8174.

## Abstract

Application Actions publishes application-level actions and prepares a selected action with semantic parameters as an ordered bundle of EVM calls. It is one optional capability of an application adapter and remains separate from Application Queries.

## Interface

The experimental interface is defined by `contracts/IApplicationActions.sol`.

## Action Discovery

`actions()` returns the action identifiers currently exposed by the resolver. Action identifiers are resolver-defined in v0. Clients MUST NOT assume a global taxonomy.

## Descriptors

`actionDescriptor(actionId)` returns adapter-defined descriptor bytes. The base interface does not freeze serialization. This repository currently evaluates the experimental JSON profile in `spec/DESCRIPTORS.md`.

Actions and queries SHOULD use one shared descriptor system. The experimental profile remains subject to change based on client and adapter findings.

## Preparation

`prepare(actionId, account, parameters)` compiles an action into an ordered call bundle.

- `account` is the account for which preparation occurs and MUST NOT be inferred from `msg.sender`.
- `parameters` use the encoding declared by the action descriptor.
- Calls MUST be returned in execution order.
- `validUntil` is an inclusive Unix timestamp after which a client MUST NOT execute the prepared calls without preparing again.
- `validUntil == 0` means that the resolver declares no time-based expiry.

Preparation MAY continue through the External Request specification in `spec/EXTERNAL_REQUEST.md`.

A terminal preparation callback MUST return data ABI-compatible with `prepare()` so the client can decode the final `PreparedAction` without callback-specific knowledge.

## Execution

This specification does not define authorization, simulation, batching, or execution. A client MUST apply its normal transaction review and authorization policy before executing returned calls.

Some protocols report business failure through successful EVM return data rather than a revert. v0 does not let a prepared action require particular return values or postconditions. Likewise, an ordered `Call[]` does not declare whether partial execution is acceptable or atomic execution is required. Clients MUST NOT infer application success solely from the absence of an EVM revert.

## Open Questions

- Descriptor serialization and semantic types.
- Application-adapter discovery and authenticity.
- Cross-chain call representation.
- Prepared-action validation beyond `validUntil`.
- Required call return values and postconditions.
- Atomicity requirements and partial-execution behavior for multi-call actions.

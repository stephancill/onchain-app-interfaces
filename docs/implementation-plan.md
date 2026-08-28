# Implementation Plan

## Objective

Build an experimental Application Interface through which a generic machine client can both:

- observe semantic application state through Application Queries;
- prepare semantic user operations through Application Actions.

Both capabilities use External Request when computation requires client-mediated HTTP data.

## Current State

Completed:

- experimental External Request ABI and normative draft;
- experimental Application Actions and Application Queries ABIs;
- TypeScript External Request continuation runtime;
- deterministic header, query, JSON, and form requirement insertion;
- sender validation, mandatory request authorization, response limits, and recursive continuation;
- Solidity fixtures and unit tests for the initial continuation flow.
- deployed Anvil-to-HTTPS-to-callback tests for both `query()` and `prepare()`;
- a combined query/action fixture covering onchain, authenticated, multi-stage, status, redirect, and form paths.
- a real fully onchain Aerodrome adapter with canonical direct-pool, LP-position, and quote queries plus direct swap preparation;
- a Base fork observe, prepare, execute, and observe-again test using the returned call bundle unchanged.
- a hybrid Moonwell adapter with external cross-market queries, onchain listed-market position aggregation, and account-aware ERC-20 supply preparation.
- KyberSwap recursive quote/build, OpenSea authenticated query/mint, and Bitrefill authenticated query-only adapters.
- an Avantis positions/open-trade adapter with strict validation of tx-builder calldata.
- consolidated cross-application findings and proposed solutions in `docs/prototype-findings.md`.
- a shared descriptor profile with generic Zod validation, ABI parameter encoding, and semantic result decoding across all six adapters.
- pre-number ERC working papers for External Request and the combined Application Queries and Actions interfaces.

Not yet demonstrated:

- adversarial transport and sensitive-result handling.

## Phase 1: End-to-End Continuation Harness

Status: completed with the local combined fixture.

Run Anvil and a local HTTP fixture to exercise the TypeScript client against deployed Solidity contracts rather than mocked EVM calls.

Cover:

1. Public request and callback.
2. Header, query, JSON, and form requirements.
3. Two-stage recursive requests.
4. Non-2xx responses.
5. Redirect refusal.
6. Sender mismatch and recursion-limit failures.

Exit criterion: one generic continuation runtime completes calls originating from both `query()` and `prepare()`.

## Phase 2: Query and Action Fixtures

Status: completed for transport and continuation behavior. Descriptor-driven encoding remains Phase 4 work.

Implement one fixture adapter exposing both optional interfaces.

Queries:

1. Entirely onchain semantic aggregate.
2. Public indexed-data request.
3. Authenticated portfolio-style request.
4. Multi-stage public then authenticated request.

Actions:

1. Entirely onchain prepared call bundle.
2. Externally quoted prepared call bundle.

Use explicit, fixture-specific ABI encodings while descriptor serialization remains unresolved.

Exit criterion: queries return semantic bytes and actions return executable calls through the same client runtime.

## Phase 3: Real Application Vertical Slice

Status: the Aerodrome fully onchain control and initial Moonwell hybrid lending slice are complete. Borrow/repay constraints and generic descriptor-driven operation remain.

The focused KyberSwap, OpenSea, and Bitrefill stress adapters are also complete. Phase 4 shared descriptor work is now the next implementation priority.

Prioritize one application adapter that supports a complete observe-act-observe flow rather than unrelated demonstrations.

Recommended first vertical slice: a lending application.

1. Query positions and active collateral.
2. Query borrow capacity or health factor.
3. Prepare a constrained borrow, repay, or collateral action.
4. Simulate and execute the prepared calls on a fork.
5. Query resulting state.

Add focused adapters for transport coverage only where the vertical slice does not exercise it:

- an ERC-4626 vault for a minimal fully onchain aggregate and action;
- a public indexer or quote endpoint;
- an authenticated quote or portfolio endpoint.

Exit criterion: the adapter materially reduces protocol-specific logic in the generic client.

## Phase 4: Shared Descriptor Prototype

Status: initial v0.1 profile implemented across all 13 adapter capabilities. Arrays, cross-field constraints, content addressing, and user-facing rendering remain deferred.

Use the implemented query inputs, query outputs, action inputs, and action effects to compare descriptor representations.

The prototype MUST let a generic client:

1. Discover queries and actions.
2. Render or construct valid semantic inputs.
3. Encode `parameters` without adapter-specific code.
4. Decode query results without adapter-specific code.
5. Explain prepared action effects and important constraints.

Evaluate ABI schemas, JSON, CBOR, content-addressed documents, and relevant ERC-7730 concepts. Do not freeze a format until at least two materially different adapters work.

## Phase 5: Threat Model and Adversarial Tests

Test request-side threats:

- credential exfiltration and origin confusion;
- redirects, DNS rebinding, private networks, and metadata services;
- duplicate or conflicting requirements;
- malformed pointers, oversized responses, and recursive exhaustion.

Test query-specific threats:

- private result logging or caching;
- exposing private data to an AI reasoning layer without policy;
- account mismatch and cross-user response confusion;
- stale indexed data and misleading provenance.

Test action-specific threats:

- stale quotes, replay, malicious call targets, and misleading effects;
- arbitrary adapters falsely claiming to represent an application.

Exit criterion: normative security requirements are backed by executable adversarial tests.

## Phase 6: Stabilization

Revisit every ABI field and deferred feature based on implementation evidence, including:

- descriptor representation;
- requirement value typing;
- response header representation;
- query freshness and sensitive-result metadata;
- `validUntil` and prepared-action validation;
- required return values, postconditions, and multi-call atomicity;
- application-adapter discovery and authenticity;
- single URL and cross-chain call representation.

Only then optimize and freeze the ABIs or submit the existing ERC working papers.

## Prototype Success Criteria

The prototype phase succeeds when:

1. A generic client discovers supported semantic queries and actions.
2. It encodes query and action inputs using descriptors alone.
3. It decodes query results using descriptors alone.
4. Queries aggregate onchain and indexed or external data.
5. Queries and actions can use private client-owned request values without exposing them to contracts.
6. The same continuation runtime handles `query()` and `prepare()`.
7. Nested requests work with deterministic interpolation and bounded recursion.
8. Returned actions can be simulated and executed by an ordinary wallet or smart account.
9. At least one real adapter supports observe, reason, act, and observe again.
10. The generic client requires materially less protocol-specific knowledge than raw ABI integration.

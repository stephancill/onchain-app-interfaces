---
name: onchain-app-interfaces
description: Read and interpret experimental Onchain Application Interfaces from deployed EVM adapters. Use when asked to inspect an application adapter address, discover its semantic queries or actions, parse query/action descriptors, encode descriptor-defined parameters, execute a semantic query, prepare an action without broadcasting it, resolve External Request HTTP continuations, or explain returned semantic results and prepared EVM call bundles.
---

# Onchain Application Interfaces

Read deployed adapters through the repository's experimental query, action, descriptor, and External Request interfaces. Treat discovery and action preparation as reads; never broadcast prepared calls unless the user separately requests execution.

## Workflow

1. Establish the chain ID, adapter address, and RPC URL. Never infer the chain from an address. If no RPC is supplied, use `https://evm.stupidtech.net/v1/<chainId>`.
2. Verify that the adapter address has bytecode. State clearly if adapter identity or authenticity is not established.
3. Find the repository root containing `contracts/IApplicationQueries.sol` and `src/client/index.ts`. Read the relevant file in `spec/` before interpreting behavior:
   - `spec/QUERIES.md` for semantic reads.
   - `spec/ACTIONS.md` for action preparation.
   - `spec/DESCRIPTORS.md` for parameters, outputs, constraints, provenance, effects, and execution metadata.
   - `spec/EXTERNAL_REQUEST.md` when a call reverts with `ExternalRequest`.
4. Discover capabilities with `queries()` and `actions()`. These interfaces are optional; report a missing or reverting capability separately instead of treating the whole adapter as invalid.
5. Fetch every relevant `queryDescriptor(bytes32)` or `actionDescriptor(bytes32)` value. Parse it with `parseApplicationDescriptor` from `src/client/index.ts`; do not hand-parse or silently accept malformed descriptors.
6. Present capability IDs as exact `bytes32` hex plus descriptor names. IDs are adapter-defined; do not infer a global taxonomy.
7. For an invocation, collect values for every named input field, apply descriptor constraints, and encode with `encodeDescriptorParameters`. Preserve integer precision with decimal strings or `bigint`; never use floating-point arithmetic for onchain units.
8. Execute the read with `resolveCall` so recursive External Requests work. Decode the top-level ABI return first. For a query, decode the resulting inner `bytes` with `decodeDescriptorResult`. For an action, decode the returned `PreparedAction` directly.
9. Report provenance, sensitivity, expiry, effects, atomicity metadata, and unresolved trust assumptions alongside the result.

## Interface Calls

Use the current Solidity interfaces as the ABI source rather than explorer-inferred ABIs:

```text
queries() -> bytes32[]
queryDescriptor(bytes32) -> bytes
query(bytes32,bytes) -> bytes

actions() -> bytes32[]
actionDescriptor(bytes32) -> bytes
prepare(bytes32,address,bytes) -> ((address target,uint256 value,bytes data)[] calls,uint256 validUntil)
```

Prefer viem and the repository helpers. Ensure the injected `ethCall` preserves EVM revert data because `resolveCall` needs it to decode `ExternalRequest`.

## External Requests

When `query` or `prepare` reverts with `ExternalRequest`:

1. Use `resolveCall`; do not recreate callback calldata manually unless diagnosing the client.
2. Require `sender` to equal the address called at that recursion step.
3. Authorize the exact HTTPS origin and enforce DNS/IP destination policy before network access. Do not automatically follow redirects.
4. Resolve every requirement explicitly. Ask the user for approval or an approved credential resolver when a value is unavailable.
5. Never print, log, persist, or place sensitive requirement values in callback calldata, diagnostics, shell arguments, or result summaries.
6. Keep the recursion limit at four or higher and enforce response-size limits.
7. Deliver non-2xx and 3xx responses to the callback unchanged; treat DNS, TLS, timeout, policy, and size failures as terminal client failures.

Do not execute side-effecting HTTP merely because an adapter requests it. Stop unless local policy establishes that the request is a safe read or an explicitly authorized computational request without durable remote effects.

## Query Results

- Decode fields by descriptor name and retain exact integer values.
- Explain semantic units only when the descriptor or trusted application context establishes them.
- Include explicit freshness fields from the result; v0 has no generic freshness wrapper.
- Apply local policy before exposing, caching, or reasoning over fields labeled `private` or `bearer-secret`.
- Describe configured-origin and hybrid results as externally sourced, not trustless.

## Prepared Actions

- Pass the intended account explicitly to `prepare`; never derive it from `msg.sender`.
- Preserve call order and display each call's target, native value, selector, and calldata.
- Treat `validUntil` as inclusive. A value of zero means no declared time expiry, not permanent safety.
- Surface descriptor effects and atomicity, but do not treat them as authorization.
- Warn that a successful EVM call may still represent application failure through return data.
- Do not simulate, sign, propose, or broadcast the calls unless the user asks. Before any later execution, re-check expiry, chain, targets, calldata semantics, simulation results, required return values, postconditions, and whether atomic execution is required.

## Output

Use a compact report containing:

- chain ID, adapter address, and RPC source;
- discovered query/action IDs and validated descriptor names;
- selected input values in semantic and encoded form, excluding secrets;
- decoded semantic result or ordered prepared calls;
- provenance, sensitivity, freshness/expiry, effects, and atomicity;
- External Requests performed by method and origin only, with sensitive values redacted;
- trust gaps, policy decisions, and anything that could not be verified.

Fail loudly on unknown descriptor versions, malformed descriptors, unsupported ABI types, constraint violations, sender mismatch, unauthorized origins, unresolved requirements, expired preparations, or ambiguous decoding.

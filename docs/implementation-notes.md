# Implementation Notes

This document records implementation findings that affect the experimental interfaces and specifications. It must not contain credentials, personal information, or private endpoint details.

## 2026-08-24

- Created the Foundry and Bun repository scaffold.
- Established separate normative drafts for External Request, Application Queries, and Application Actions.
- Marked all v0 interfaces as experimental.
- Chose string values as the initial requirement-satisfaction representation.
- Chose a structured HTTP response containing status, headers, and body for the v0 callback.
- Defined deterministic header, query, JSON-object, and form-field insertion rules.
- Defined v0 redirects as manual: 3xx responses reach the callback and credentials are never forwarded automatically.
- Implemented a TypeScript continuation client with injected EVM calls, requirement resolution, request authorization, and HTTP transport.
- Made request authorization mandatory and ordered it before all HTTP execution.
- Added configurable recursion and response-body limits.
- Added Solidity fixtures for structured callbacks and nested requests.
- Added client vectors covering request interpolation, sender validation, recursive continuation, and policy rejection.
- Added Application Queries as a separate optional application-adapter capability sharing External Request.
- Renamed the experimental action interface from `IActionResolver` to `IApplicationActions` and renamed `descriptor()` to `actionDescriptor()`. No compatibility alias was retained because the ABI is experimental.
- Kept account identity as an ordinary encoded query parameter rather than a distinguished `query()` argument.
- Deferred generic query freshness wrappers and sensitive-result metadata until real adapters demonstrate common requirements.
- Added an end-to-end harness that deploys a combined query/action fixture to Anvil and serves a local test API over HTTPS.
- Confirmed that callback return values can preserve the originating `query()` or `prepare()` return ABI, allowing one continuation runtime to handle both capabilities.
- Made terminal callback return-type compatibility a normative External Request requirement based on that finding.
- Confirmed that non-2xx and 3xx responses reach callbacks unchanged and that the Fetch transport does not follow redirects when configured with `redirect: "manual"`.
- Confirmed real callback recursion, recursion-limit enforcement, sender mismatch rejection, and header/query/JSON/form interpolation.
- Localhost and the self-signed test certificate are authorized only by the injected test policy and test transport; production request validation remains HTTPS-only and requires explicit authorization.
- Added a Base-only Aerodrome adapter for the direct volatile WETH/USDC pool as the fully onchain control.
- Kept best-route discovery out of the control adapter; it supports one explicit direct route and uses the live Aerodrome Router for quoting.
- Added semantic pool-state, pro-rata LP-position, and exact-input quote queries.
- Added exact-input swap preparation with account-aware approvals, a 1,000 bps slippage cap, router deadline validation, and `validUntil` equal to that deadline.
- Executed the returned approval and swap calls unchanged on a Base fork and queried reserves before and after to demonstrate observe, act, and observe again.
- Added a Moonwell hybrid adapter whose cross-market positions and health queries use External Request while its USDC position and supply preparation use live onchain state.
- Bound external Moonwell results to query ID and account while retaining the API JSON body; this demonstrates the need for descriptors that can identify JSON media types and output schemas.
- Constructed Moonwell action calls locally rather than trusting API-provided transaction targets or calldata.
- Verified a Moonwell supply bundle on a Base fork, including conditional approval and collateral-market entry.
- Confirmed that Compound v2 operations can return business-error codes without reverting. `Call[]` cannot currently require successful return values, providing a concrete use case for prepared-action validation or postconditions.
- Confirmed that approval, collateral entry, and mint can partially execute when a consumer submits calls non-atomically. `PreparedAction` does not currently express atomicity requirements or acceptable partial completion.
- Added a recursive KyberSwap adapter that preserves a quoted route object across callbacks and strictly decodes API-generated router calldata.
- Added an OpenSea adapter using a sensitive `x-api-key` requirement and onchain SeaDrop validation for public mint calldata.
- Added a Bitrefill query-only adapter using a sensitive `X-Access-Token` requirement; checkout and payment were excluded because they create remote state and require x402/SIWX workflows outside `PreparedAction`.
- Added narrow JSON utilities with top-level field scoping, duplicate rejection, nested-object extraction, and strict primitive decoding. These are not intended as a general JSON standard.
- Consolidated implementation findings and proposed solutions in `docs/prototype-findings.md`.
- Added the experimental shared JSON descriptor profile in `spec/DESCRIPTORS.md` and replaced all placeholder descriptor strings across 13 capabilities.
- Added a Zod-validated TypeScript descriptor parser with generic ABI tuple encoding, semantic enum values, constraint checks, and named result decoding.
- Used descriptor-derived parameters and result decoding in end-to-end tests across all five adapters.
- Measured inline descriptor bytecode cost: KyberSwap runtime reached approximately 22.9 KB, leaving about 1.6 KB below EIP-170. Content-addressed or separate descriptor storage should be tested before expanding schemas substantially.
- Confirmed that HTTPS origin policy authenticates transport but does not make external query data trustless; result provenance must be represented to clients.

## Verification

- `forge test`: 24 passing tests.
- Base Aerodrome fork suite: 8 passing tests, including prepared-call execution.
- Base Moonwell fork suite: 7 passing tests, including supply execution and return-code checks.
- `bun test`: 29 passing tests, including 16 Anvil/HTTPS integration tests.
- `tsc --noEmit`: passing.
- `oxlint .`: passing with no warnings.

## Open Validation Work

- Validate JSON insertion rules through independently implemented test vectors.
- Validate callback and nested sender semantics against ERC-3668 behavior.
- Stress-test origin authorization, redirects, SSRF protections, and response limits.
- Prototype content-addressed descriptor retrieval and authenticity.
- Add adversarial tests for malformed API calldata, sensitive result disclosure, and side-effecting HTTP.
- Prototype simulation return assertions, postcondition queries, and multi-call atomicity requirements.

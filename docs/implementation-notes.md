# Implementation Notes

This document records implementation findings that affect the experimental interfaces and specifications. It must not contain credentials, personal information, or private endpoint details.

## 2026-08-25

- Generalized the Aerodrome adapter from one embedded WETH/USDC pool to caller-selected canonical Base pools. Every query and action now validates factory membership, derives pool tokens and the stable flag onchain, and remains restricted to one direct route through the canonical router and factory.
- Replaced Moonwell's USDC-specific onchain capabilities with `moonwell.position` and `moonwell.supply` for listed Base ERC-20 markets. The adapter validates the canonical Comptroller and listing, resolves the underlying token from the market, and never accepts user-provided protocol or underlying targets.
- Renamed the web examples to Aerodrome and Moonwell and added usable WETH/USDC-pool and mUSDC defaults for the generalized descriptor fields. Existing verified deployment addresses still contain the earlier narrow adapters and require replacement deployments before the generalized capabilities are available on Base.
- Verified 37 local Forge tests, 12 Aerodrome Base-fork tests, 10 Moonwell Base-fork tests, 30 Bun tests, Forge lint and formatting, root TypeScript formatting/lint/typechecking, and the web production build. Runtime sizes remain below EIP-170 at 17,056 bytes for Aerodrome and 18,940 bytes for Moonwell.
- Deployed and verified the Avantis application adapter on Base at `0x53c8B42bf72C286e453D56F74831E9DFb975b0d6` with the canonical core API and transaction-builder origins, then added it to the web examples with both origins allowlisted and complete open-trade defaults.
- Added `aerodrome.pool` and `moonwell.market` onchain search queries so generic clients can resolve canonical pool and listed-market contract addresses from token addresses before using state, position, quote, or action capabilities. Missing and ambiguous matches fail explicitly.
- Deployed and verified the generalized Aerodrome adapter on Base at `0x31cB53007f5fDECEAa84d43ad4E387A081E13f7b` and the generalized Moonwell adapter at `0x805E521b5BD349B02380DC0C81bcd75bDb374FD2`, then replaced the legacy addresses in the web examples. Both runtimes match local artifacts; live search calls resolve the canonical WETH/USDC pool and mUSDC market.
- Added two pre-number ERC working papers under `docs/eips/`: External HTTP Request Continuations and the combined Application Query and Action Interfaces proposal.
- Followed the active EIP-1 and ERC repository structure, retained separate optional query and action ABIs in one application-interface proposal, and left descriptor serialization implementation-defined pending content-addressing and authenticity work.
- Recorded the remaining pre-submission requirements: dedicated public discussion URLs, editor-assigned numbers, canonical repository validation, and ABI stabilization.
- Scoped the root Bun test script to `test/` so ignored upstream guidance clones under `third-party/` are not mistaken for project test suites.
- Deployed and verified the Moonwell application adapter on Base at `0xFe58AD745170163A133895fAE16ea9D3021Dd281` with the canonical `https://api.moonwell.fi` origin; runtime bytecode matches locally and the web client completed a live `moonwell.health` External Request continuation.
- Added a web-console examples table for the verified Aerodrome and Moonwell adapters and moved non-sensitive adapter, RPC, activation, and origin state into nuqs URL parameters. External Request requirement values remain local and are never put in the URL.
- Added prepared-action wallet execution through EIP-5792 `wallet_sendCalls`, with connected-wallet and account checks, chain switching, expiry validation, call-order preservation, wallet bundle status reporting, and mandatory atomic requests for descriptors marked `atomic-required`. Atomic-required actions never fall back to sequential transactions.
- Deployed and verified the Aerodrome application adapter on Base at `0x6Be0EeB08795EE4fca64FC643Dfe2e77227EFD93` through txlink; its runtime bytecode matches the local artifact and live discovery returns the expected three queries and one action.
- Seeded the web console's Aerodrome quote and swap forms with the adapter's supported WETH/USDC pair and valid raw-unit examples; generic zero-address defaults caused the quote query to revert with `UnsupportedPair`.
- Added a Bun/create-wagmi Vite web console for loading deployed adapters, validating descriptors, encoding semantic inputs, resolving explicitly permitted External Requests, decoding query results, and preparing action bundles without execution.
- Replaced Node-specific descriptor hex decoding with viem's browser-safe `hexToBytes` so the shared client can run in Vite.
- The web console uses an exact HTTP-origin allowlist but explicitly does not claim production-grade DNS rebinding or private-network enforcement; browser CORS also remains applicable.
- Added an Avantis hybrid adapter exposing account-bound positions and open-trade preparation for Base, based on the Base MCP Avantis plugin.
- Used the live Avantis `/v2/trade/open` endpoint because the tx-builder OpenAPI has moved from the unversioned route still shown in the linked plugin document.
- Kept protocol inputs in canonical onchain units and converted them to the tx-builder's human-decimal query format without floating-point arithmetic.
- Required the tx-builder response to preserve Base chain ID, signer, canonical Trading target, exact execution fee, and every decoded `openTrade` field. The service supplies validation and encoding but cannot change action semantics.
- Added exact USDC approval only when TradingStorage allowance is insufficient and declared approval plus trade atomic-required.
- Limited prepared-action freshness to five minutes because pair listing, leverage envelopes, market hours, and open-interest capacity can change after tx-builder validation.
- Extended generic descriptor and External Request end-to-end coverage to 15 capabilities across six adapters.
- Measured Avantis adapter runtime at approximately 23.3 KB, leaving approximately 1.3 KB below EIP-170 and reinforcing the need to move descriptors out of adapter bytecode.
- Added a top-level web console About section linking the repository, agent skill, and both pre-number ERC working papers.
- Current verification: 30 Forge tests and 30 Bun tests pass; formatting, Oxlint, and TypeScript checks pass.

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

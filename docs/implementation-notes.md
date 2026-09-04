# Implementation Notes

This document records implementation findings that affect the experimental interfaces and specifications. It must not contain credentials, personal information, or privately funded endpoint details.

## 2026-09-03

- Fixed the `relay.bridge.exactInput` transform, which was broken at two levels (and had never run live because a panic fired first). The defects in `RelayApplicationAdapter._stepsTransform` were (1) a wrapping `TUPLE` root that emitted `abi.encode(tuple{array,...})` instead of the bare `RelayStep[]` that `prepareCallback` decodes, and (2) an extra 1-field tuple wrapping each item's five-field `/data` tuple. The root is now the bare `ARRAY "/steps"` and each item's transaction is the five-field `data` tuple directly (10 nodes). Verified end-to-end on an Anvil Base fork with a live `/quote/v2` to `api.relay.link`: `resolveCall` now carries `prepare` through the `ExternalRequest` continuation and decodes a correct `PreparedAction` — one origin-chain call to depository `0x4cD0…`, value `1000000000000000`, recipient calldata, plus `validUntil`. Note: the adapter I deployed earlier (`0x1E80534C558Cb50567cF77b5EC7271c46d76633e`) was built from the still-broken transform and must be redeployed with this fix to actually work.
- Separately fixed an array-out-of-bounds `panic 0x32` in `_stepsTransform` (it allocated `new JsonAbiNode[](11)` but wrote 12 nodes) and strengthened `testPrepareExitsViaExternalRequest` to require the `ExternalRequest` custom error rather than accepting the `0x4eee8b71` panic.

## 2026-08-30

- Added a chain-agnostic hybrid Relay adapter (`contracts/adapters/RelayApplicationAdapter.sol`): an indicative `relay.route.quote` query and an executable `relay.bridge.exactInput` action over Relay's `POST /quote/v2`. The action reduces the returned origin-chain EVM steps into an ordered `PreparedAction` (approve → deposit/swap), keeping the deposit `to`/`data` verbatim per Relay's guidance and never hardcoding the depository. Deployed bytecode is 13113 bytes (under EIP-170) with inline descriptors and a 11-node JSON_ABI projection tree.
- Confirmed that intent/solver protocols invert the usual "one chain" shape: `prepare()` returns only the **origin**-chain calls; destination settlement is solver-mediated and cannot be expressed as EVM call data. Recorded this and the supporting constraints in `docs/adapters/relay.md`. The adapter requests `usePermit:false` and reverts loudly on any returned `kind:"signature"` step because `PreparedAction` cannot carry a signature leg.
- Bound the action to semantic parameters rather than a fixed chain: `originChainId`/`destinationChainId` are request fields, so one deployed adapter quotes and prepares any Relay-supported origin chain. Callback validation enforces `chainId == originChainId`, `from == preparer`, a non-empty origin transaction set, and a per-call value-overdraw bound (`value > amount` reverts). `validUntil` is derived from the requested `ttlSeconds`.
- Uses a sensitive `x-api-key` `RequestRequirement` for both the query and the action; the key never enters callback calldata or result bodies. Unit-covered behavior is 9 Forge tests (flattening, overdraw, non-origin chain, unbound sender, signature rejection, empty quote, query raw body, discovery, and the eager ExternalRequest exit).
- Deployed the Relay adapter to Base mainnet (8453) pointing at `https://api.relay.link` and verified it on BaseScan (solc v0.8.30, optimizer 200, runtime 13113 bytes): `0x2BE7659C8e7627F1C2aB08CebA6bcb72D50747E5` (deployer `0x8d25687829D6b85d9e0020B8c89e3Ca24dE20a89`; tx `0x54eaf447b3e420943e763ad2a792fa698956c68b23fb3e690db5b893de1a61c9`). Added it to the web console `examples` list with `https://api.relay.link` as the allowlisted external origin, and prefill editor values for a Base→Optimism native bridge/swap; Relay still requires the caller to paste the `x-api-key` in the External Request policy.
- Fixed a web-console parse failure surfaced by the Relay adapter: the action descriptor's cross-chain `increase` effect carries `chainIdField`, which the client's strict effect schema rejected (`unrecognized_keys`). Added `chainIdField` as an optional, inert effect field in `src/client/descriptor.ts` and covered it with a unit test in `test/client/descriptor.test.ts`. No adapter redeploy was needed; the client now reparses the already-deployed descriptor.
- Removed the `x-api-key` `RequestRequirement` from the Relay adapter after confirming via the relay skill that the header is optional and only raises rate limits. Redeployed `RelayApplicationAdapter("https://api.relay.link")` to Base (runtime now 12,979 bytes) at `0x37A3adb94423358EaaD8Ae3aF9c721fDD95cE04B` (tx `0x4125e3f37f39a5f5e5df360c2b2197493961b7cfb8846e9a45f507fa1b42eb1c`) and repointed the web console example to it. The Relay example now runs without pasting an API key.

## 2026-08-28

- Aligned `docs/eips/erc-draft-external-request.md` with the response-projection feature landed in earlier today: the draft now defines `ResponseBodyEncoding`, `ResponseTransformKind`, `JsonAbiNodeType`, `JsonAbiNode`, and `ResponseTransform` in its normative ABI, replacing the `uint8 bodyEncoding` and the deferral to the experimental spec. Added a normative Response Transformation section (preorder projection tree, coercion rules, fail-closed behavior, raw-body commitment, status gating), updated the HTTP Response and Continuation Encoding test vectors, and added a projection round-trip test plus Rationale and Denial-of-Service notes. Deliberately kept descriptor serialization implementation-defined as before; only the projection ABI and semantics were folded into the draft.

## 2026-08-28

- Deployed and verified the three web-console reference adapters on Base mainnet (8453), each a single `eth_sendTransaction` from the console deployer:
  - Aerodrome adapter `0x9c952d2530e8e94512f14fe6987fccb5d8a3b6e2`; Moonwell adapter `0xf5c03ce6356d9dafe49f3254b38f7e747958b0c0`; Avantis adapter `0x02a1c3b80ceedc01f8d83ee49f194b6d5bdf9232`. Each had a successful receipt (status 0x1) and live runtime bytecode (Aerodrome 8.9 KB, Moonwell 10.4 KB, Avantis 22.8 KB).
- Updated the web console's example adapter list in `web/src/App.tsx` to point at the freshly deployed contracts so the demo loads the live adapters. Verified on Base that Aerodrome and Moonwell each return 5 query ids.
- Fixed the `avantis.markets` Web console crash (`viem IntegerOutOfRangeError` during result decode). The `meta`, `markets`, and `market` query descriptors omitted the `rawBodyHash` (bytes32) component that every `AvantisExternalQueryResult` actually encodes, so the client decoded the 32-byte `rawBodyHash` slot as the `body` offset and viem threw on the huge number. Added `rawBodyHash` (in ABI struct order, after `status`) to all three descriptors; the `positions` descriptor already had it. Verified with 31 Forge + 38 Bun tests and by decoding a real-shaped `AvantisExternalQueryResult`, then redeployed the fixed Avantis adapter to `0xfa5725214419f9688133841f67e10c4783d17b26` (block 50,562,683) and repointed the web example at it (the earlier `0x02a1c3b80ceedc01f8d83ee49f194b6d5bdf9232` now carries the buggy descriptors).
- Made raw JSON bodies in query results readable in the web console: `decodeDescriptorResult` now decodes `bytes` fields marked `contentType: "application/json"` (and not `bearer-secret`) into a parsed object instead of a hex blob, so results such as `avantis.markets` show the JSON payload. Updated the client unit and e2e tests accordingly (39 passing).
- Verified the deployed example adapters on Basescan with `forge verify-contract` (solc v0.8.30, optimizer 200): Aerodrome `0x9c952d2530e8e94512f14fe6987fccb5d8a3b6e2`, Moonwell `0xf5c03ce6356d9dafe49f3254b38f7e747958b0c0`, Avantis `0xfa5725214419f9688133841f67e10c4783d17b26` and its descriptor companion `0x4FC86132480B888fB8dc16090A692a291a3611C6` — all returned "Pass - Verified".

## 2026-08-28

- Fixed the web console's responsive layout after the Tailwind v4 migration. Three issues surfaced when tested in a browser across 375/768/900/1280/1920 px viewports:
  - Horizontal page overflow in the two-column capability grid (0 px before, up to ~150 px at tablet widths after migration). The raw descriptor/result `<pre>` content forced the card's single auto grid track wider than its column because unbreakable JSON/AAB hex tokens set a large grid min-content. Fixed by giving the card's grid children `min-w-0` (`[&>*]:min-w-0`) and making `pre` wrap/break long lines (`white-space: pre-wrap`, `word-break: break-word`, `min-width: 0`) so the pre cannot inflate the track.
  - The capability card summary row fragmented awkwardly at narrow widths (the truncated id and status dot wrapping to a second line because of a `justify-between`+`flex-1` spacer in a `flex-wrap` container). Replaced it with a two-part grid/flex summary: on mobile the kind badge, name, and chevron sit on one line with the status dot and id on the next; on `md:` and up it is a single justified flex row with a hidden duplicate chevron.
  - The app filled only a fixed 1200 px centered column: `<main>` used `w-[min(1200px,calc(100%-2rem))]`, so on wide windows the app stayed pinned at 1200 px and resizing between ~1200 px and the full window width produced no visible change. Changed `<main>` to `w-full` with responsive `px-4 sm:px-6 lg:px-8` padding so the app now spans the full viewport and reflows live on resize.
- Verified in the browser that `<main>` matches the viewport width at 600/900/1280/1920 px with no horizontal overflow, `document.scrollWidth === clientWidth` at every width, and the capability grid still collapses to a single column below the `md:` breakpoint. Current verification: web `bun run check` passes.

## 2026-08-28

- Migrated the interactive web console in `web/` (Vite, React, wagmi) to Tailwind CSS v4 for its responsive layout and component styling.
- Added the `@tailwindcss/vite` plugin and wired it into `vite.config.ts`; `index.css` is now a Tailwind entry that imports Tailwind plus minimal base-layer rules for form controls, page height, links, and wrapping.
- Replaced every ad-hoc class in `App.tsx` with Tailwind utility classes, preserving the prior behavior: the two-column query/action capability grid and the four-column target form collapse via `max-md:` breakpoints, and expandable capability cards use the `group-open:` variant with a `group` class on `<details>` to rotate the summary chevron.
- Verified the production build emits the expected `::-webkit-details-marker` override and all responsive/grid/`max-md:` variants. Current verification: web `bun run check` (format, lint, typecheck, build) passes.

## 2026-08-28

- Expanded the Avantis adapter from one query and one action to five queries and eight actions covering metadata, markets, account state, positions, opening, closing, pending-order management, position increases, margin changes, and expiring delegates.
- Migrated reads and transaction preparation to the live Avantis v2 tx-builder surface. The Base MCP plugin v0.2 still documents several removed unversioned routes and older position response shapes.
- Required byte-for-byte calldata equality for deterministic builder actions. Margin updates instead validate every semantic field and canonical encoding while accepting fresh Pyth update bytes that the protocol verifies onchain.
- Kept USDC approvals local, exact, conditional, and ordered before collateral-pulling actions. Delegate calls are also constructed locally because they need no external validation.
- Did not expose active-position TP/SL updates because Avantis v2 now provides only EIP-712 intent builders for that operation, while `PreparedAction` can represent only EVM calls. This is a concrete requirement for a future signature-preparation capability.
- Moved Avantis JSON descriptors into an automatically deployed companion contract. Descriptor separation alone did not make the comprehensive unoptimized adapter deployable; enabling the Solidity optimizer reduced runtime from approximately 33.4 KB to under EIP-170.
- Added descriptor-driven end-to-end coverage for all externally built Avantis actions, including independent calldata reconstruction, fixed-point URL conversion, dynamic oracle data, approvals, and call ordering.
- Added response transformations to External Request. Contracts now declare a `ResponseTransform` that the continuation client applies before invoking the callback.
- Introduced a flattened preorder projection tree (`JsonAbiNode[]`) covering scalars, tuples, arrays of tuples, and nested arrays with strict bounds, relative RFC 6901 JSON Pointers, and deterministic coercion without floating-point intermediates.
- Expanded `HttpResponse` with a raw-body `keccak256` commitment and a `bodyEncoding` discriminator. Non-2xx statuses are still delivered raw so callbacks keep full control of error bodies.
- Replaced Avantis's onchain JSON parsing with client-side projection. Transaction and positions callbacks now `abi.decode` typed structs; account binding, chain, target, signer, value, and built calldata are still verified in Solidity. The margin callback still decodes builder-supplied Pyth update bytes.
- Measured the resulting callback gas reduction on the Avantis unit suite: open-trade callback fell from approximately 3.8 million to approximately 26 thousand simulated gas, and the margin callback from approximately 3.1 million to approximately 107 thousand.
- Simplified the `avantis.positions` result from an opaque JSON body to named arrays of trade and order tuples, and extended the descriptor profile to describe `tuple[]` fields so a generic client can decode them.
- Confirmed viem covers all recursive ABI construction for projections; the only new client machinery is a strict JSON parser and projection evaluator. Duplicate object keys, missing fields, oversized arrays, and malformed trees fail closed.
- Current verification: 31 Forge tests and 38 Bun tests pass, including new transform unit tests and the expanded Avantis e2e flow.

## 2026-08-28

- Restored the interactive web console in `web/` (Vite, React, wagmi) that was previously reverted, and adapted it to the current adapters and `avantis.*` capability names.
- Made `parseApplicationDescriptor` browser-portable by replacing Node's `Buffer` with viem's `hexToBytes`; the browser test surfaced this as the only client dependency on Node globals.
- Ran the console in a real Chromium browser against fresh adapter deployments on a local Anvil, with the HTTP fixture tunneled through a public HTTPS endpoint so the client's HTTPS requirement and origin authorization hold in the browser.
- Verified in the browser: Avantis `avantis.positions` resolves through External Request and renders the projected typed trade/order tuples; `avantis.trade.open` prepares the USDC approval plus `openTrade` bundle from a projected transaction; Moonwell `moonwell.health` delivers its RAW JSON body bound to the requested account.
- Replaced the console's raw JSON input textarea with a structured descriptor-driven editor: per-field text inputs, boolean checkboxes, enum selects, nested tuple fieldsets, inline validation, and a read-only encoded-values preview. Verified in the browser that controls update the encoded values and that address/integer validation messages surface.
- Collapsed capabilities by default into expandable cards with a compact summary header and status dots for pending, failed, and completed results.
- Split the capability list into two side-by-side columns on wide screens: queries on the left and actions on the right, with a single-column stack on small screens.
- Fixed a bottom-scroll failure risk on macOS: removed `overflow-y: auto` on the root element (a Safari footgun with `min-height` bodies) and capped tall `pre` blocks so large results cannot stretch the page unreachably.
- Current verification: 31 Forge tests and 38 Bun tests pass; root and web `bun run check`, `forge fmt`, and web production build all pass.

## 2026-08-25

- Added two pre-number ERC working papers under `docs/eips/`: External HTTP Request Continuations and the combined Application Query and Action Interfaces proposal.
- Followed the active EIP-1 and ERC repository structure, retained separate optional query and action ABIs in one application-interface proposal, and left descriptor serialization implementation-defined pending content-addressing and authenticity work.
- Recorded the remaining pre-submission requirements: dedicated public discussion URLs, editor-assigned numbers, canonical repository validation, and ABI stabilization.
- Scoped the root Bun test script to `test/` so ignored upstream guidance clones under `third-party/` are not mistaken for project test suites.
- Added an Avantis hybrid adapter exposing account-bound positions and open-trade preparation for Base, based on the Base MCP Avantis plugin.
- Used the live Avantis `/v2/trade/open` endpoint because the tx-builder OpenAPI has moved from the unversioned route still shown in the linked plugin document.
- Kept protocol inputs in canonical onchain units and converted them to the tx-builder's human-decimal query format without floating-point arithmetic.
- Required the tx-builder response to preserve Base chain ID, signer, canonical Trading target, exact execution fee, and every decoded `openTrade` field. The service supplies validation and encoding but cannot change action semantics.
- Added exact USDC approval only when TradingStorage allowance is insufficient and declared approval plus trade atomic-required.
- Limited prepared-action freshness to five minutes because pair listing, leverage envelopes, market hours, and open-interest capacity can change after tx-builder validation.
- Extended generic descriptor and External Request end-to-end coverage to 15 capabilities across six adapters.
- Measured Avantis adapter runtime at approximately 23.3 KB, leaving approximately 1.3 KB below EIP-170 and reinforcing the need to move descriptors out of adapter bytecode.
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

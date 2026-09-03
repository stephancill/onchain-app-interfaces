# Usability Review — Driving the Onchain Application Interface skill through an adapter

Usability feedback gathered from an agent driving the router skill end-to-end against a live adapter. It is a working review document: use it to iterate on the skill, the reference client, and the reference repo. It does **not** contain credentials or anything sensitive.

**Scope of the exercise:** take the router skill document, find the reference repository, discover and read a deployed adapter's semantic queries/actions, and prepare a `$10 USDC/BTC long` on an Avantis adapter on Base without executing it.

**Outcome:** the flow completed successfully. The adapter was discovered, BTC/USD market data was retrieved live, and a 2-call `PreparedAction` (USDC approve → Avantis `openTrade`) was produced and decoded, honoring the skill's "do not broadcast unless asked" rule. The failures below are all around *client plumbing*, never the on-chain interface contract itself.

The single biggest takeaway: **the interface concept and `resolveCall` machinery are solid; the rough edges are entirely about client boilerplate every agent/person must re-derive by hand.** A few small helpers would eliminate most of it.

---

## 1. Reference repository location is not documented

The skill says:

> Find the repository root containing `contracts/IApplicationQueries.sol` and `src/client/index.ts`.

It never says where that root lives or how to get it. An agent (or human) must `find` for it, and whether to clone is ambiguous. On top of that, the skill did **not** load via the runtime `skill` tool; I had to fetch the doc from its `pages.dev` URL manually. That coupling (skill doc → needed repo) is undocumented.

**Suggestion:** ship the skill with (a) a canonical clone URL, (b) a note that the client is usable as a local package in the repo, and (c) optionally publish the client so a consumer doesn't have to clone.

## 2. `parseAbi` / `encodeFunctionData`, never hand-written selectors

The interface is presented as `queries() -> bytes32[]` etc. but selectors are not listed. I hand-wrote selectors from memory and got them wrong, then verified with `cast sig`. That's exactly the class of silently-wrong artifact the skill warns against.

**Recommendation:** add a rule to the skill: encode through `parseAbi` + `encodeFunctionData` (or the provided client's ABI) and never derive selectors by hand. Confirmed with `cast sig`: `queries() = 0x3e66eca0`, `actions() = 0xf99e36bc`, `queryDescriptor(bytes32) = 0x49b7d2ea`, `actionDescriptor(bytes32) = 0xafef12a0`, valid as of this review.

## 3. `decodeFunctionResult` returns a bare value for single-output functions

Destructuring as `const [d] = decodeFunctionResult(...)` returns the string `"0"`/first character, not the bytes field. Single-output functions need no destructure. This is a viem gotcha, not a bug, but it wasted a cycle and is easy to get backwards.

## 4. Decoding the `PreparedAction` return shape

The `prepare` return is a single nested tuple of `(Call[] calls, uint256 validUntil)`. Declaring it flattened caused `PositionOutOfBounds`, and `data.slice(10)` to strip the 4-byte function selector must instead be `slice(8)`. Both were "ambiguous decoding" failures the skill correctly says to "fail loudly" on — and it did, but each fix took another pass.

**Recommendation:** add one concrete worked decode example to the skill/repo for (a) the multi-arg vs single-value `decodeFunctionResult` case and (b) the nested `Call[]` + `validUntil` tuple, including the selector-offset gotcha. This is the most page-consuming part of the whole flow.

## 5. BigInt breaks naive output

`JSON.stringify` throws on `bigint`, and every decode returns bigints. This broke the result reporting twice until a replacer was added. Not the skill's fault — but the skill asks for compact reporting and does not mention that all decode output must be BigInt-aware.

**Recommendation:** add a `stringify` helper (with `bigint` replacer) to the client exports and mention it in the skill's reporting guidance.

## 6. `bun` package resolution fails when scripts run outside the repo

Importing `viem` failed to resolve `@noble/hashes/crypto` when my script sat in `/tmp`; running from the repo's `node_modules` worked. Fixed by keeping helper scripts inside the project. Worth a one-liner so other agents avoid the same 20‑minute detour.

---

## What worked well (keep it)

- The **ordered workflow** (chain → bytecode → discover → descriptors → prepare) kept verification steps necessary.
- `resolveCall` handled the full external-request lifecycle (sender-match, origin auth, HTTP GET to the configured `tx-builder.avantisfi.com`, response transform) **end-to-end on a live adapter** with only a small `ethCall`/`authorizeRequest`/`fetch`-object harness.
- `parseApplicationDescriptor` + `encodeDescriptorParameters` + `decodeDescriptorResult` removed hand param-encoding once they were wired through.
- The "prepare only, never broadcast unless asked" guardrail is exactly right for the teaching/first-phase use case.
- The guidance to treat configured-origin/hybrid results as "externally sourced, not trustless" is good discipline.

## Highest-leverage changes (in priority order)

1. Add a **single canonical "adapter client" helper** in the reference repo wrapping: `ethCall` + `encodeFunctionData` + `resolveCall` + `decode(FunctionResult | DescriptorResult)` for both `query` and `prepare`. This single change would remove failure modes 2, 3 and 4.
2. **Document the repo location / clone step** (or publish the client). Removes failure #1.
3. **BigInt-safe output** (`stringify`) in the shared helpers. Removes #5.
4. **Two worked decode examples** (single-output gotcha + nested prepared-action tuple). Removes #4.

## Skills-level observation

Nothing here — the interface is intentionally experimental — but the velocity hit of the "hand-derived plumbing" is real. If the community is the intended audience, either a thin package or a single-page "minimal client" that shows the 30 lines that do discovery+query+prepare would improve the experience more than any other change.

*Recorded at review time — prices/observedAt are from the live run (BTC/USD ≈ 79,224 at prepare). The market data is a snapshot, not the point of this doc; the plumbing findings are.*
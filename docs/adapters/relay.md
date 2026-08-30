# Relay Application Adapter

## Status

Experimental hybrid query/action adapter implemented in `contracts/adapters/RelayApplicationAdapter.sol`. It is not pinned to a single origin chain; every request carries `originChainId`/`destinationChainId`, so the same adapter can quote and prepare EVM deposits on any Relay-supported origin chain.

## Capabilities

- `relay.route.quote` — an indicative EXACT_INPUT preview. It POSTs `/quote/v2` with `indicativeQuote: true` and returns the raw response body bound to the requested chain pair and amount.
- `relay.bridge.exactInput` — POSTs an executable `/quote/v2` and reduces the returned origin-chain EVM steps (`approve` → `deposit`/`swap`) into an ordered `PreparedAction` bundle.

Both POST `/quote/v2` with no authentication requirement (Relay's `x-api-key` is optional and only raises rate limits). The adapter declares no `RequestRequirement`, so a client can run the example without supplying a key.

## Execution Model

Relay's quotes are short-lived solver intents. The deposit transaction on the origin chain is submitted by the user, and the solver fulfills on the destination. The adapter therefore:

- takes every projected `steps[].items[].data` transaction step that is bound to the origin chain and emits it as a `Call` in step-then-item order (approval first, then deposit/swap); the returned deposit `to`/`data` is used verbatim and never hardcoded;
- sets `validUntil` from the requested `ttlSeconds` (quotes are re-quoted rather than reused);
- enforces `chainId == originChainId`, `from == account`, and that no single call debits more than the requested `amount`.

## Explicit Non-Goals (Findings)

- **Destination fulfillment is outside `PreparedAction`.** Relay settles on the destination chain via its own depository and solver. That leg cannot be expressed as EVM calls on the origin chain, so the prepared action is inherently one-sided. Consumers must still track the `requestId` and destination arrival separately; the adapter does not model intent status.
- **Signature steps are rejected.** Permits (EIP-3009/Permit2) and some routes return `kind: "signature"` steps, which `PreparedAction` cannot represent. The adapter requests `usePermit: false` and reverts loudly on any returned signature step rather than silently dropping it.
- **Downstream resolution is not atomic and not verifiable from the origin bundle.** Preparation validates origin calls structurally, but it cannot attest that the solver will fill. A client must apply its normal review/authorization policy and its own intent monitoring.

## Validation

The request body is constructed only from validated parameters: chains, currencies (native is the zero address), `amount` (EXACT_INPUT), `slippageBps` (0–10000), and `ttlSeconds` (1–3600). Callbacks validate the projected steps against those same parameters: account binding on `from`, `chainId == originChainId`, a non-empty origin transaction set, and a value-overdraw bound. Malformed or mismatched projected responses revert before any `Call` is produced.

## Why This Is a Hybrid That Skips Destination Logic

The action's value is turning an executable solver quote into the origin-side calls a wallet can sign. Doing it requires the two-EVM-leg context that Application Actions does not model; the honest output is one-sided and the intent must be tracked externally. This mirrors the KyberSwap/OpenSea finding that a transaction-builder response still requires strict semantic decoding, and extends it: a relay/intents product pushes the *second half* of the "action" outside what an EVM call bundle can hold.
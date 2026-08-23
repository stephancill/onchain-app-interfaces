# Bitrefill Application Adapter

## Status

Experimental query-only adapter implemented in `contracts/adapters/BitrefillApplicationAdapter.sol`.

## Capabilities

- `bitrefill.catalog.search` searches gift cards, eSIMs, or top-ups.
- `bitrefill.product.detail` retrieves product details.

Both require a sensitive `X-Access-Token` header containing an existing Bitrefill JWT. Inputs are bounded and structurally encoded; callers cannot supply an arbitrary origin or path. Responses require HTTP 200, JSON media type, a JSON-shaped body, and a size bound.

## Why There Are No Actions

Checkout is not transaction preparation. Creating an invoice mutates remote state, and payment requires x402 negotiation, user authorization, an onchain payment, an HTTP retry carrying proof, asynchronous fulfillment, and delivery polling.

Executing those operations while resolving `prepare()` would cause side effects during simulation and could create duplicate invoices or payments. `PreparedAction` cannot represent remote idempotency, HTTP/EVM atomicity, fulfillment, or sensitive redemption results.

The adapter therefore demonstrates that implementations may safely expose queries only and should fail loudly rather than disguising commerce as `Call[]` preparation.

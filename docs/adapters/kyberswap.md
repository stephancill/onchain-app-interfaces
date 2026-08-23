# KyberSwap Application Adapter

## Status

Experimental Base-only exact-input swap adapter implemented in `contracts/adapters/KyberSwapApplicationAdapter.sol`.

## Capability

The adapter exposes `kyberswap.swap.exactInput` for ERC-20 WETH/USDC swaps. Parameters include exact input, an explicit user minimum output, slippage basis points, and a deadline.

Preparation performs two recursive External Requests:

1. `GET /base/api/v1/routes` obtains a route summary.
2. The quote callback embeds that exact summary into `POST /base/api/v1/route/build`.
3. The build callback validates and returns approval plus router calls.

The user minimum output is independent of the API quote. The adapter rejects routes below it.

## Validation

The adapter pins the Base Kyber router, rejects API fees and native value, and ABI-decodes the returned router calldata. It verifies tokens, recipient, input amount, minimum return, source-amount totals, empty fee arrays, empty permit data, and canonical calldata encoding before returning a call.

Response and calldata sizes are bounded. Only WETH and USDC are supported in this prototype.

## Finding

Recursive External Request is sufficient for quote-then-build workflows. However, preserving and extracting nested JSON in Solidity is expensive and API-specific. HTTPS alone is not enough when an API returns executable calldata; callbacks must decode and validate it against semantic parameters.

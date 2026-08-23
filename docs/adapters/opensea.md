# OpenSea Application Adapter

## Status

Experimental authenticated Base adapter implemented in `contracts/adapters/OpenSeaApplicationAdapter.sol`.

## Capabilities

- `opensea.collection.stats` returns API JSON bound to a validated collection slug.
- `opensea.drop.mint.public` prepares one canonical public SeaDrop mint.

Both use a sensitive `x-api-key` header requirement. The API key remains in the client and HTTP request and never enters callback calldata or results.

## Mint Validation

The adapter restricts collection slugs, requires Base, pins the configured SeaDrop contract, decodes `mintPublic(address,address,address,uint256)`, and binds the NFT contract, minter, and quantity to semantic parameters.

It then reads the public drop configuration onchain and verifies stage activity, wallet quantity limit, exact mint value, and the user's maximum total value. `validUntil` is the onchain public-stage end time.

Allowlist, signed, token-gated, custom SeaDrop, cross-chain, and arbitrary fulfillment calldata are intentionally unsupported.

## Finding

`RequestRequirement` cleanly models an existing API key. Authentication grants API access but does not make returned transaction calldata trustworthy. An authenticated transaction-builder response still requires strict protocol-specific decoding and onchain validation.

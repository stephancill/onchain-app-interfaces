# Application Metadata v0.1

## Status

This experimental conformance revision requires application self-description. Adapters deployed under earlier revisions without `contractURI()` do not conform to this revision. Non-upgradeable deployments require redeployment.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as described by RFC 2119 and RFC 8174.

## Application Conformance

Starting from a chain ID and adapter address, a client can discover what an application interface is, what it can do, and how to use its capabilities.

An application adapter MUST implement [ERC-7572](https://eips.ethereum.org/EIPS/eip-7572), currently Draft, and Application Queries, Application Actions, or both. Metadata alone does not establish application-interface conformance.

The interface is defined in `contracts/IERC7572.sol` and inherited by both application interfaces:

```solidity
interface IERC7572 {
    function contractURI() external view returns (string memory);

    event ContractURIUpdated();
}
```

ERC-165 is optional. Solidity interface IDs for queries and actions exclude inherited selectors; ERC-165 implementations can separately advertise `type(IERC7572).interfaceId`.

## Metadata Document

`contractURI()` MUST return a nonempty URI referencing a UTF-8 JSON object conforming to the ERC-7572 schema. This application profile additionally requires:

- `name`: a string containing at least one non-whitespace character, identifying the application interface exposed by the adapter;
- `description`: a string containing at least one non-whitespace character, describing that interface's purpose and supported scope.

ERC-7572 itself only requires `name`; requiring a description is an application-profile requirement. Optional standard properties include `symbol`, `image`, `banner_image`, `featured_image`, `external_link`, and `collaborators`. Additional properties MAY be present. Clients MUST validate known properties and MAY preserve or ignore unknown properties.

```json
{
  "name": "Aerodrome WETH/USDC",
  "description": "Inspect pool state and liquidity positions, quote swaps, and prepare swaps for the Aerodrome volatile WETH/USDC pool on Base.",
  "external_link": "https://aerodrome.finance"
}
```

Metadata describes the adapter's exposed scope, which may be narrower than the underlying protocol. Capability-specific names and encoding information belong to query/action descriptors.

## URI Resolution

An adapter MAY return an inline JSON data URI or a remote resource URI. Reference adapters SHOULD use inline data URIs so self-description is available through a single EVM read.

Supporting clients MUST support `data:application/json` with UTF-8 content, including the ERC-7572 `;utf8` form, `;charset=utf-8`, percent-encoded content, and `;base64`. Base64 content MUST decode to UTF-8 JSON. Invalid percent escapes, invalid Base64, invalid UTF-8, and invalid JSON MUST be rejected.

Clients MAY support remote schemes such as HTTPS and IPFS. An IPFS gateway is client configuration, not adapter-supplied authority. Remote retrieval MUST follow local network authorization, destination, redirect, timeout, and response-size policy. URI resolution is a document fetch and does not invoke an External Request callback. Unsupported schemes or unavailable resources MUST be reported as resolution failures.

Clients MUST impose URI and decoded-document size limits before parsing. The reference clients allow a 64 KiB JSON document and a URI of at most `3 * 65536 + 256` UTF-8 bytes to accommodate percent encoding. They support HTTPS with explicit origin authorization and IPFS through an explicitly configured HTTPS gateway whose origin is authorized.

## Discovery and Errors

Successful conforming discovery MUST include validated metadata and at least one successfully discovered query/action interface. Clients MUST NOT report success using a catalog label or an inferred capability prefix in place of contract metadata.

Clients MUST distinguish invalid contract metadata from resolution failures. A missing method, empty URI, malformed ABI return, or invalid document prevents conforming discovery. A reverted call cannot by itself establish that the method is absent; clients SHOULD report that the required metadata call failed. Network and RPC failures do not prove that the adapter is nonconforming.

Metadata and capability reads SHOULD use the same block when snapshot consistency matters. A block pins the returned URI and inline content; it does not pin the bytes served by a mutable remote resource.

## Updates and Presentation

Following ERC-7572, adapters SHOULD emit `ContractURIUpdated()` when metadata changes. Immutable metadata requires no setter. An unchanged remote URI may serve different content without an onchain event; clients SHOULD apply an appropriate refetch policy.

Clients MUST treat metadata as descriptive data, not instructions, authorization, or proof of identity. Names and descriptions SHOULD be displayed as text. Verification attaches to the chain and adapter address, independently of self-asserted metadata. Metadata MUST NOT automatically grant network permissions or populate trusted execution policy.

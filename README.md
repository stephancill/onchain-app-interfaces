# Onchain Application Interfaces

Experimental standards and reference implementations for:

- discovering application names and descriptions through required ERC-7572 contract metadata;
- discovering and executing application-level semantic queries;
- discovering application-level actions and preparing them as EVM call bundles;
- continuing EVM calls through client-mediated external HTTP requests.

The design context is in the [original technical handover](docs/Technical%20Handover_%20Application%20Action%20Resolver%20and%20External%20Request%20Standards.md) and its [Application Query supplement](docs/Supplemental%20Handover_%20Application%20Query%20Interface.md). The consolidated delivery sequence is in [`docs/implementation-plan.md`](docs/implementation-plan.md).

Normative drafts live in `spec/`. Solidity interfaces live in `contracts/`. The TypeScript reference client lives in `src/client/`.

The agent skill lives in [`skills/onchain-app-interfaces/`](skills/onchain-app-interfaces/) and includes a Python 3.9+, standard-library-only command-line client. It can discover, query, and prepare against an adapter without cloning dependencies or resolving JavaScript packages.

OpenCode discovers the skill locally through this repository's `opencode.json`. Remote users can add `https://onchain-app-interfaces.pages.dev/.well-known/skills/` to their OpenCode `skills` configuration; the Pages build generates that catalog directly from the canonical `skills/` directory.

Pre-number ERC working papers live in [`docs/eips/`](docs/eips/). They are formatted for eventual submission but remain subordinate to the experimental specifications until the ABIs are stabilized.

- `spec/QUERIES.md` defines semantic application reads.
- `spec/METADATA.md` defines required ERC-7572 self-description and application conformance.
- `spec/ACTIONS.md` defines semantic action preparation.
- `spec/EXTERNAL_REQUEST.md` defines their shared external continuation mechanism.
- `spec/DESCRIPTORS.md` defines the experimental shared descriptor profile.

Reference adapters live in `contracts/adapters/`:

- a fully onchain [Aerodrome WETH/USDC adapter](docs/adapters/aerodrome.md);
- a hybrid [Moonwell USDC adapter](docs/adapters/moonwell.md) combining external semantic queries with onchain action preparation.
- a recursive [KyberSwap quote/build adapter](docs/adapters/kyberswap.md);
- an authenticated [OpenSea stats/public-mint adapter](docs/adapters/opensea.md);
- a query-only [Bitrefill catalog adapter](docs/adapters/bitrefill.md);
- a comprehensive hybrid [Avantis markets and position-management adapter](docs/adapters/avantis.md) with validated tx-builder calldata.
- a chain-agnostic hybrid [Relay bridge/swap adapter](docs/adapters/relay.md) that reduces an EXACT_INPUT `/quote/v2` intent to its origin-chain EVM deposit bundle.

Cross-application evidence and proposed standards changes are consolidated in [`docs/prototype-findings.md`](docs/prototype-findings.md).

## Status

All interfaces are experimental and may change based on implementation findings.

The v0.1 conformance revision requires `contractURI()` with nonempty `name` and `description`, plus queries, actions, or both. All seven reference adapters return inline JSON metadata. The Aerodrome, Moonwell, Avantis, and Relay Base examples were redeployed with metadata on 2026-09-20; their current addresses are in the adapter documentation and `web/public/interfaces.json`. Earlier deployments without metadata do not conform to this revision.

## Development

```sh
bun install
forge build
bun run check
forge test
```

The end-to-end tests additionally require `anvil` and `openssl`. They compile and deploy the fixture automatically:

```sh
bun run test:e2e
```

A full local stack for the `web/` console is available with `bun scripts/dev-stack.ts`: anvil with all three hybrid adapters deployed and a local API fixture exposed over a public HTTPS tunnel. It prints the RPC URL, adapter addresses, and tunnel origin to use as the console's External Request allowlist. Start the console itself with `cd web && bun run dev`.

## Reference Client

`resolveCall` accepts injected EVM, requirement-resolution, authorization, and HTTP functions. Requirement values are passed only to HTTP request construction and are never included in callback calldata.

```typescript
import { resolveCall } from "./src/client/index.ts";

const result = await resolveCall({
  call,
  ethCall,
  resolveRequirement: ({ requirement, request }) =>
    credentialStore.resolve({ requirement, origin: new URL(request.url).origin }),
  authorizeRequest: ({ completedRequest, requirements }) =>
    requestPolicy.authorize({ completedRequest, requirements }),
});
```

`authorizeRequest` is mandatory and runs before network access. It must enforce origin authorization, DNS/IP destination policy, and any user-consent requirements. It must not log sensitive requirement values.

`stringifyJson` serializes decoded values with bigints represented as decimal strings.

`readContractMetadata({ address, ethCall, ...options })` reads and validates required ERC-7572 metadata and returns `{ uri, metadata }`. `resolveContractMetadata({ uri, ...options })` resolves an already-read URI. Inline UTF-8, percent-encoded, and Base64 JSON data URIs are supported. Remote HTTPS retrieval requires `authorizeRequest`; IPFS additionally requires an `ipfsGateway` HTTPS origin. The same origin, destination, timeout, and response-limit policy applies to remote metadata retrieval as to other client-mediated HTTP. Metadata documents are limited to 64 KiB.

## Skill Client

The bundled skill client can run from any directory and has no package-install step:

```sh
python3 skills/onchain-app-interfaces/scripts/adapter.py discover \
  --chain-id 8453 \
  --adapter 0x300030fea92f4281894aefde5f2261fe12c0afdb
```

Its `query` and `prepare` commands accept descriptor values from a JSON file or stdin, derive selectors from canonical signatures, resolve recursive External Requests, and emit BigInt-safe JSON. External HTTP is denied unless its exact HTTPS origin is passed with `--allow-origin`; DNS answers must all be public, and the connection is pinned to a validated address while TLS continues to verify the original hostname. The client never executes prepared calls.

All commands validate required application metadata and include `contractURI` and `metadata` in their output. Authorize remote metadata origins with `--allow-origin`; resolve IPFS metadata with `--ipfs-gateway https://<gateway-host>` plus its allowed origin. Inline reference-adapter metadata requires only RPC access.

## Web Console

An interactive Vite and React console lives in [`web/`](web/). It connects a wallet through wagmi, loads any adapter by chain ID, RPC URL, and address, discovers queries and actions, runs semantic queries, prepares action bundles, and submits them with EIP-5792 `wallet_sendCalls` after review.

A live demo is deployed at <https://onchain-app-interfaces.pages.dev/> (Cloudflare Pages).

```sh
cd web
bun install
bun run dev
```

External Requests require an exact origin allowlist entered on the page, and target APIs must permit browser CORS. The browser cannot enforce the full DNS and private-network policy of a production client.

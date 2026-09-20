# Application Interface Console

A Vite and React console, scaffolded with `bun create wagmi`, for discovering and interacting with experimental Onchain Application Interface adapters.

A live demo is deployed at <https://onchain-app-interfaces.pages.dev/> (Cloudflare Pages).

The console reads descriptors, encodes semantic inputs, resolves permitted External Requests, decodes query results, and prepares action call bundles. Prepared bundles can be submitted through a connected wallet after review.

Loading an adapter requires ERC-7572 `contractURI()` metadata with nonempty name and description, displayed as contract-provided text above its capabilities. Metadata and capability reads use one block. Inline UTF-8, percent-encoded, and Base64 JSON are supported. Configure remote metadata origins and an optional IPFS gateway under **Metadata and HTTP settings** before loading. Retrieval and validation errors prevent conforming discovery.

The four Base example addresses point to metadata-capable deployments from 2026-09-20. The Pages build publishes the canonical skill instructions and bundled Python client from `../skills/` through its generated `.well-known/skills/` catalog.

Wallet execution uses EIP-5792 `wallet_sendCalls`. Actions marked `atomic-required` set `atomicRequired` and never fall back to sequential transactions. The connected wallet must match the preparation account, and expired preparations are rejected.

```sh
bun install
bun run dev
```

External Requests require an exact origin allowlist. The browser cannot enforce the complete DNS and private-network policy required of a production client, and target APIs must permit browser CORS.

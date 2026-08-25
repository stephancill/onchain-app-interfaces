# Application Interface Console

A Vite and React console, scaffolded with `bun create wagmi`, for discovering and interacting with experimental Onchain Application Interface adapters.

The console reads descriptors, encodes semantic inputs, resolves permitted External Requests, decodes query results, and prepares action call bundles. Prepared bundles can be submitted through a connected wallet after review.

Wallet execution uses EIP-5792 `wallet_sendCalls`. Actions marked `atomic-required` set `atomicRequired` and never fall back to sequential transactions. The connected wallet must match the preparation account, and expired preparations are rejected.

```sh
bun install
bun run dev
```

External Requests require an exact origin allowlist. The browser cannot enforce the complete DNS and private-network policy required of a production client, and target APIs must permit browser CORS.

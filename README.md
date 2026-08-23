# Onchain Application Interfaces

Experimental standards and reference implementations for:

- discovering and executing application-level semantic queries;
- discovering application-level actions and preparing them as EVM call bundles;
- continuing EVM calls through client-mediated external HTTP requests.

The design context is in the [original technical handover](docs/Technical%20Handover_%20Application%20Action%20Resolver%20and%20External%20Request%20Standards.md) and its [Application Query supplement](docs/Supplemental%20Handover_%20Application%20Query%20Interface.md). The consolidated delivery sequence is in [`docs/implementation-plan.md`](docs/implementation-plan.md).

Normative drafts live in `spec/`. Solidity interfaces live in `contracts/`. The TypeScript reference client lives in `src/client/`.

- `spec/QUERIES.md` defines semantic application reads.
- `spec/ACTIONS.md` defines semantic action preparation.
- `spec/EXTERNAL_REQUEST.md` defines their shared external continuation mechanism.
- `spec/DESCRIPTORS.md` defines the experimental shared descriptor profile.

Reference adapters live in `contracts/adapters/`:

- a fully onchain [Aerodrome WETH/USDC adapter](docs/adapters/aerodrome.md);
- a hybrid [Moonwell USDC adapter](docs/adapters/moonwell.md) combining external semantic queries with onchain action preparation.
- a recursive [KyberSwap quote/build adapter](docs/adapters/kyberswap.md);
- an authenticated [OpenSea stats/public-mint adapter](docs/adapters/opensea.md);
- a query-only [Bitrefill catalog adapter](docs/adapters/bitrefill.md).

Cross-application evidence and proposed standards changes are consolidated in [`docs/prototype-findings.md`](docs/prototype-findings.md).

## Status

All interfaces are experimental and may change based on implementation findings.

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

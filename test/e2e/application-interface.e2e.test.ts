import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  decodeAbiParameters,
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  http,
  keccak256,
  stringToHex,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import { z } from "zod";

import { resolveCall } from "../../src/client/index.ts";
import type {
  AuthorizeRequest,
  HttpFetch,
  ResolveRequirement,
} from "../../src/client/types.ts";

const artifactSchema = z.object({
  abi: z.array(z.unknown()),
  bytecode: z.object({ object: z.string().regex(/^0x[0-9a-fA-F]+$/) }),
});

const queryIds = {
  onchain: keccak256(stringToHex("fixture.query.onchain")),
  requirements: keccak256(stringToHex("fixture.query.requirements")),
  nested: keccak256(stringToHex("fixture.query.nested")),
  status: keccak256(stringToHex("fixture.query.status")),
  redirect: keccak256(stringToHex("fixture.query.redirect")),
  form: keccak256(stringToHex("fixture.query.form")),
  mismatch: keccak256(stringToHex("fixture.query.mismatch")),
} as const;

const actionIds = {
  onchain: keccak256(stringToHex("fixture.action.onchain")),
  external: keccak256(stringToHex("fixture.action.external")),
} as const;

const moonwellQueryIds = {
  positions: keccak256(stringToHex("moonwell.positions")),
  health: keccak256(stringToHex("moonwell.health")),
} as const;

const testPrivateKey =
  // Public default Anvil account #0 key. Never use outside ephemeral test chains.
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as Hex;

let anvil: ReturnType<typeof Bun.spawn>;
let httpsServer: ReturnType<typeof Bun.serve>;
let temporaryDirectory: string;
let rpcUrl: string;
let serviceOrigin: string;
let adapterAddress: Address;
let adapterAbi: Abi;
let moonwellAddress: Address;
let moonwellAbi: Abi;

function reservePort(): number {
  const server = Bun.serve({ port: 0, fetch: () => new Response() });
  const port = server.port;
  server.stop(true);
  if (port === undefined) throw new Error("Could not reserve an Anvil port");
  return port;
}

async function waitForAnvil(): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const response = await fetch(rpcUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "eth_chainId",
          params: [],
        }),
      });
      if (response.ok) return;
    } catch {
      await Bun.sleep(25);
    }
  }
  throw new Error("Anvil did not start");
}

function createCertificate(): { key: string; cert: string } {
  temporaryDirectory = mkdtempSync(
    join(tmpdir(), "application-interface-e2e-"),
  );
  const key = join(temporaryDirectory, "key.pem");
  const cert = join(temporaryDirectory, "cert.pem");
  const result = Bun.spawnSync([
    "openssl",
    "req",
    "-x509",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-keyout",
    key,
    "-out",
    cert,
    "-days",
    "1",
    "-subj",
    "/CN=127.0.0.1",
    "-addext",
    "subjectAltName=IP:127.0.0.1",
  ]);
  if (result.exitCode !== 0) {
    throw new Error(
      `Could not create test certificate: ${result.stderr.toString()}`,
    );
  }
  return { key, cert };
}

function startHttpsServer(parameters: { key: string; cert: string }) {
  return Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    tls: {
      key: Bun.file(parameters.key),
      cert: Bun.file(parameters.cert),
    },
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname === "/requirements") {
        if (request.headers.get("authorization") !== "Bearer fixture-secret") {
          return new Response("missing authorization", { status: 401 });
        }
        if (url.searchParams.get("account_id") !== "account 1") {
          return new Response("missing query requirement", { status: 400 });
        }
        const body = (await request.json()) as {
          context?: { account?: unknown };
        };
        if (body.context?.account !== "body-account") {
          return new Response("missing body requirement", { status: 400 });
        }
        return new Response("requirements-ok", { status: 200 });
      }
      if (url.pathname === "/public") return new Response("public-ok");
      if (url.pathname === "/authenticated") {
        return request.headers.get("authorization") === "Bearer fixture-secret"
          ? new Response("nested-ok")
          : new Response("missing authorization", { status: 401 });
      }
      if (url.pathname === "/status")
        return new Response("rate-limited", { status: 429 });
      if (url.pathname === "/redirect") {
        return new Response("redirect-body", {
          status: 302,
          headers: { Location: `${serviceOrigin}/requirements` },
        });
      }
      if (url.pathname === "/action") return new Response("quoted-action");
      if (url.pathname === "/form") {
        const body = new URLSearchParams(await request.text());
        return body.get("asset") === "ETH" &&
          body.get("api_key") === "form secret/value"
          ? new Response("form-ok")
          : new Response("missing form requirement", { status: 400 });
      }
      if (url.pathname.startsWith("/v1/health/")) {
        return Response.json({
          success: true,
          data: {
            address: url.pathname.slice("/v1/health/".length),
            healthFactor: 2.5,
          },
        });
      }
      if (url.pathname.startsWith("/v1/positions/")) {
        return Response.json({
          success: true,
          data: [
            { market: "mUSDC", suppliedUsd: 100, collateralEnabled: true },
          ],
        });
      }
      return new Response("not found", { status: 404 });
    },
  });
}

const localHttpsFetch: HttpFetch = (input, init) =>
  fetch(input, {
    ...init,
    tls: { rejectUnauthorized: false },
  } as BunFetchRequestInit);

const resolveRequirement: ResolveRequirement = ({ requirement }) => {
  if (requirement.path === "Authorization") return "Bearer fixture-secret";
  if (requirement.path === "account_id") return "account 1";
  if (requirement.path === "/context/account") return "body-account";
  if (requirement.path === "api_key") return "form secret/value";
  throw new Error(`Unexpected requirement: ${requirement.path}`);
};

const authorizeRequest: AuthorizeRequest = ({ completedRequest }) => {
  if (new URL(completedRequest.url).origin !== serviceOrigin) {
    throw new Error("Test request origin is not explicitly authorized");
  }
};

async function resolveAdapterCall(parameters: {
  data: Hex;
  maxRequests?: number;
}): Promise<Hex> {
  return resolveContractCall({
    to: adapterAddress,
    data: parameters.data,
    ...(parameters.maxRequests === undefined
      ? {}
      : { maxRequests: parameters.maxRequests }),
  });
}

async function resolveContractCall(parameters: {
  to: Address;
  data: Hex;
  maxRequests?: number;
}): Promise<Hex> {
  const publicClient = createPublicClient({
    chain: foundry,
    transport: http(rpcUrl),
  });
  return resolveCall({
    call: { to: parameters.to, data: parameters.data },
    ethCall: async (call) => {
      const response = await publicClient.call(call);
      return response.data ?? "0x";
    },
    resolveRequirement,
    authorizeRequest,
    fetch: localHttpsFetch,
    ...(parameters.maxRequests === undefined
      ? {}
      : { maxRequests: parameters.maxRequests }),
  });
}

function queryCall(queryId: Hex, parameters: Hex = "0x"): Hex {
  return encodeFunctionData({
    abi: adapterAbi,
    functionName: "query",
    args: [queryId, parameters],
  });
}

beforeAll(async () => {
  const build = Bun.spawnSync(["forge", "build"], {
    stdout: "pipe",
    stderr: "pipe",
  });
  if (build.exitCode !== 0) throw new Error(build.stderr.toString());

  const certificate = createCertificate();
  httpsServer = startHttpsServer(certificate);
  serviceOrigin = `https://127.0.0.1:${httpsServer.port}`;

  const anvilPort = reservePort();
  rpcUrl = `http://127.0.0.1:${anvilPort}`;
  anvil = Bun.spawn(["anvil", "--port", String(anvilPort), "--quiet"], {
    stdout: "pipe",
    stderr: "pipe",
  });
  await waitForAnvil();

  const artifact = artifactSchema.parse(
    await Bun.file(
      "out/ApplicationAdapterFixture.sol/ApplicationAdapterFixture.json",
    ).json(),
  );
  adapterAbi = artifact.abi as Abi;
  const moonwellArtifact = artifactSchema.parse(
    await Bun.file(
      "out/MoonwellApplicationAdapter.sol/MoonwellApplicationAdapter.json",
    ).json(),
  );
  moonwellAbi = moonwellArtifact.abi as Abi;

  const account = privateKeyToAccount(testPrivateKey);
  const publicClient = createPublicClient({
    chain: foundry,
    transport: http(rpcUrl),
  });
  const walletClient = createWalletClient({
    account,
    chain: foundry,
    transport: http(rpcUrl),
  });
  const deployment = await walletClient.deployContract({
    abi: adapterAbi,
    bytecode: artifact.bytecode.object as Hex,
    args: [serviceOrigin],
  });
  const receipt = await publicClient.waitForTransactionReceipt({
    hash: deployment,
  });
  if (receipt.contractAddress == null)
    throw new Error("Fixture deployment did not return an address");
  adapterAddress = receipt.contractAddress;

  const moonwellDeployment = await walletClient.deployContract({
    abi: moonwellAbi,
    bytecode: moonwellArtifact.bytecode.object as Hex,
    args: [serviceOrigin],
  });
  const moonwellReceipt = await publicClient.waitForTransactionReceipt({
    hash: moonwellDeployment,
  });
  if (moonwellReceipt.contractAddress == null)
    throw new Error("Moonwell fixture deployment did not return an address");
  moonwellAddress = moonwellReceipt.contractAddress;
}, 30_000);

afterAll(async () => {
  httpsServer?.stop(true);
  anvil?.kill();
  if (temporaryDirectory !== undefined)
    rmSync(temporaryDirectory, { recursive: true, force: true });
});

describe("application interface end-to-end", () => {
  test("resolves an onchain semantic query without HTTP", async () => {
    const result = await resolveAdapterCall({
      data: queryCall(
        queryIds.onchain,
        encodeAbiParameters([{ type: "uint256" }], [21n]),
      ),
    });
    const semanticResult = decodeFunctionResult({
      abi: adapterAbi,
      functionName: "query",
      data: result,
    }) as Hex;
    expect(decodeAbiParameters([{ type: "uint256" }], semanticResult)[0]).toBe(
      42n,
    );
  });

  test("completes header, query, and JSON requirements through real HTTP", async () => {
    const result = await resolveAdapterCall({
      data: queryCall(queryIds.requirements),
    });
    const semanticResult = decodeFunctionResult({
      abi: adapterAbi,
      functionName: "query",
      data: result,
    }) as Hex;
    expect(
      new TextDecoder().decode(Buffer.from(semanticResult.slice(2), "hex")),
    ).toBe("requirements-ok");
  });

  test("handles recursive public and authenticated query requests", async () => {
    const result = await resolveAdapterCall({
      data: queryCall(queryIds.nested),
    });
    const semanticResult = decodeFunctionResult({
      abi: adapterAbi,
      functionName: "query",
      data: result,
    }) as Hex;
    expect(
      new TextDecoder().decode(Buffer.from(semanticResult.slice(2), "hex")),
    ).toBe("nested-ok");
  });

  test("completes form requirements through real HTTP", async () => {
    const result = await resolveAdapterCall({ data: queryCall(queryIds.form) });
    const semanticResult = decodeFunctionResult({
      abi: adapterAbi,
      functionName: "query",
      data: result,
    }) as Hex;
    expect(
      new TextDecoder().decode(Buffer.from(semanticResult.slice(2), "hex")),
    ).toBe("form-ok");
  });

  test("delivers non-2xx and redirect responses to callbacks", async () => {
    for (const [queryId, expectedStatus, expectedBody] of [
      [queryIds.status, 429, "rate-limited"],
      [queryIds.redirect, 302, "redirect-body"],
    ] as const) {
      const result = await resolveAdapterCall({ data: queryCall(queryId) });
      const semanticResult = decodeFunctionResult({
        abi: adapterAbi,
        functionName: "query",
        data: result,
      }) as Hex;
      const [status, body] = decodeAbiParameters(
        [{ type: "uint16" }, { type: "bytes" }],
        semanticResult,
      );
      expect(status).toBe(expectedStatus);
      expect(new TextDecoder().decode(Buffer.from(body.slice(2), "hex"))).toBe(
        expectedBody,
      );
    }
  });

  test("prepares an entirely onchain action without HTTP", async () => {
    const account = "0x000000000000000000000000000000000000beef" as Address;
    const data = encodeFunctionData({
      abi: adapterAbi,
      functionName: "prepare",
      args: [actionIds.onchain, account, "0x1234"],
    });
    const result = await resolveAdapterCall({ data });
    const prepared = decodeFunctionResult({
      abi: adapterAbi,
      functionName: "prepare",
      data: result,
    }) as {
      calls: readonly { target: Address; value: bigint; data: Hex }[];
      validUntil: bigint;
    };

    const preparedCall = prepared.calls[0];
    if (preparedCall === undefined)
      throw new Error("Prepared action did not contain a call");
    expect(preparedCall.target.toLowerCase()).toBe(account);
    expect(preparedCall.value).toBe(0n);
    expect(preparedCall.data).toBe("0x1234");
    expect(prepared.validUntil).toBe(0n);
  });

  test("resolves an externally quoted prepared action with the same runtime", async () => {
    const account = "0x000000000000000000000000000000000000beef" as Address;
    const data = encodeFunctionData({
      abi: adapterAbi,
      functionName: "prepare",
      args: [actionIds.external, account, "0x1234"],
    });
    const result = await resolveAdapterCall({ data });
    const prepared = decodeFunctionResult({
      abi: adapterAbi,
      functionName: "prepare",
      data: result,
    }) as {
      calls: readonly { target: Address; value: bigint; data: Hex }[];
      validUntil: bigint;
    };

    expect(prepared.calls).toHaveLength(1);
    const preparedCall = prepared.calls[0];
    if (preparedCall === undefined)
      throw new Error("Prepared action did not contain a call");
    expect(preparedCall.target.toLowerCase()).toBe(account);
    expect(
      new TextDecoder().decode(Buffer.from(preparedCall.data.slice(2), "hex")),
    ).toBe("quoted-action");
    expect(prepared.validUntil).toBeGreaterThan(
      BigInt(Math.floor(Date.now() / 1000)),
    );
  });

  test("enforces the recursive request limit against real callbacks", async () => {
    expect(
      resolveAdapterCall({ data: queryCall(queryIds.nested), maxRequests: 1 }),
    ).rejects.toThrow("limit of 1 exceeded");
  });

  test("rejects a mismatched sender before HTTP execution", async () => {
    expect(
      resolveAdapterCall({ data: queryCall(queryIds.mismatch) }),
    ).rejects.toThrow("sender does not match");
  });
});

describe("Moonwell external queries end-to-end", () => {
  for (const [name, queryId, expectedBody] of [
    ["health", moonwellQueryIds.health, "healthFactor"],
    ["positions", moonwellQueryIds.positions, "mUSDC"],
  ] as const) {
    test(`resolves the ${name} query through External Request`, async () => {
      const account = "0x000000000000000000000000000000000000beef" as Address;
      const data = encodeFunctionData({
        abi: moonwellAbi,
        functionName: "query",
        args: [queryId, encodeAbiParameters([{ type: "address" }], [account])],
      });
      const result = await resolveContractCall({ to: moonwellAddress, data });
      const semanticResult = decodeFunctionResult({
        abi: moonwellAbi,
        functionName: "query",
        data: result,
      }) as Hex;
      const [queryResult] = decodeAbiParameters(
        [
          {
            type: "tuple",
            components: [
              { name: "queryId", type: "bytes32" },
              { name: "account", type: "address" },
              { name: "status", type: "uint16" },
              { name: "body", type: "bytes" },
              { name: "observedAt", type: "uint256" },
            ],
          },
        ],
        semanticResult,
      );

      expect(queryResult.queryId).toBe(queryId);
      expect(queryResult.account.toLowerCase()).toBe(account);
      expect(queryResult.status).toBe(200);
      expect(
        new TextDecoder().decode(Buffer.from(queryResult.body.slice(2), "hex")),
      ).toContain(expectedBody);
      expect(queryResult.observedAt).toBeGreaterThan(0n);
    });
  }
});

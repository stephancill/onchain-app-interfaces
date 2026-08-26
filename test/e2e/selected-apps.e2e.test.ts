import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  decodeFunctionResult,
  encodeFunctionData,
  http,
  keccak256,
  parseAbi,
  parseUnits,
  stringToHex,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import { z } from "zod";

import {
  decodeDescriptorResult,
  encodeDescriptorParameters,
  parseApplicationDescriptor,
  resolveCall,
  type ApplicationDescriptor,
} from "../../src/client/index.ts";
import type {
  AuthorizeRequest,
  HttpFetch,
  ResolveRequirement,
} from "../../src/client/types.ts";

const artifactSchema = z.object({
  abi: z.array(z.unknown()),
  bytecode: z.object({ object: z.string().regex(/^0x[0-9a-fA-F]+$/) }),
  deployedBytecode: z.object({ object: z.string().regex(/^0x[0-9a-fA-F]+$/) }),
});

const kyberSwapAbi = parseAbi([
  "function swap((address callTarget,address approveTarget,bytes targetData,(address srcToken,address dstToken,address[] srcReceivers,uint256[] srcAmounts,address[] feeReceivers,uint256[] feeAmounts,address dstReceiver,uint256 amount,uint256 minReturnAmount,uint256 flags,bytes permit) desc,bytes clientData) execution)",
]);
const seaDropMintAbi = parseAbi([
  "function mintPublic(address nftContract,address feeRecipient,address minter,uint256 quantity)",
]);
const avantisTradingAbi = parseAbi([
  "function openTrade((address trader,uint256 pairIndex,uint256 index,uint256 initialPosToken,uint256 positionSizeUSDC,uint256 openPrice,bool buy,uint256 leverage,uint256 tp,uint256 sl,uint256 timestamp) trade,uint8 orderType,uint256 slippagePercent) payable returns (uint256 orderId)",
]);

const testPrivateKey =
  // Public default Anvil account #0 key. Never use outside ephemeral test chains.
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as Hex;
const account = privateKeyToAccount(testPrivateKey);
const weth = "0x4200000000000000000000000000000000000006" as Address;
const usdc = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address;
const aerodromeWethUsdcPool =
  "0xcDAC0d6c6C59727a65F871236188350531885C43" as Address;
const kyberRouter = "0x6131B5fae19EA4f9D964eAc0408E4408b66337b5" as Address;
const avantisTrading = "0x44914408af82bC9983bbb330e3578E1105e11d4e" as Address;
const feeRecipient = "0x000000000000000000000000000000000000fee1" as Address;

let anvil: ReturnType<typeof Bun.spawn>;
let server: ReturnType<typeof Bun.serve>;
let temporaryDirectory: string;
let rpcUrl: string;
let serviceOrigin: string;
let seaDropAddress: Address;
let nftAddress: Address;
let kyberAddress: Address;
let openSeaAddress: Address;
let bitrefillAddress: Address;
let aerodromeAddress: Address;
let moonwellAddress: Address;
let avantisAddress: Address;
let kyberAbi: Abi;
let openSeaAbi: Abi;
let bitrefillAbi: Abi;
let aerodromeAbi: Abi;
let moonwellAbi: Abi;
let avantisAbi: Abi;
let kyberRequestCount = 0;

function reservePort(): number {
  const reservation = Bun.serve({ port: 0, fetch: () => new Response() });
  const port = reservation.port;
  reservation.stop(true);
  if (port === undefined) throw new Error("Could not reserve an Anvil port");
  return port;
}

async function rpc(method: string, params: unknown[]): Promise<unknown> {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const payload = (await response.json()) as {
    result?: unknown;
    error?: { message: string };
  };
  if (payload.error !== undefined) throw new Error(payload.error.message);
  return payload.result;
}

async function waitForAnvil(): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      await rpc("eth_chainId", []);
      return;
    } catch {
      await Bun.sleep(25);
    }
  }
  throw new Error("Anvil did not start");
}

function createCertificate(): { key: string; cert: string } {
  temporaryDirectory = mkdtempSync(join(tmpdir(), "selected-apps-e2e-"));
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
  if (result.exitCode !== 0) throw new Error(result.stderr.toString());
  return { key, cert };
}

function kyberCalldata(parameters: {
  sender: Address;
  amountIn: bigint;
  minAmountOut: bigint;
}): Hex {
  return encodeFunctionData({
    abi: kyberSwapAbi,
    functionName: "swap",
    args: [
      {
        callTarget: "0x0000000000000000000000000000000000001234",
        approveTarget: "0x0000000000000000000000000000000000000000",
        targetData: "0x1234",
        desc: {
          srcToken: weth,
          dstToken: usdc,
          srcReceivers: [kyberRouter],
          srcAmounts: [parameters.amountIn],
          feeReceivers: [],
          feeAmounts: [],
          dstReceiver: parameters.sender,
          amount: parameters.amountIn,
          minReturnAmount: parameters.minAmountOut,
          flags: 512n,
          permit: "0x",
        },
        clientData: "0x",
      },
    ],
  });
}

function startServer(certificate: { key: string; cert: string }) {
  return Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    tls: { key: Bun.file(certificate.key), cert: Bun.file(certificate.cert) },
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname === "/base/api/v1/routes") {
        kyberRequestCount += 1;
        return Response.json({
          code: 0,
          message: "successfully",
          data: {
            routeSummary: {
              tokenIn: url.searchParams.get("tokenIn"),
              tokenOut: url.searchParams.get("tokenOut"),
              amountIn: url.searchParams.get("amountIn"),
              amountOut: "2400000",
              extraFee: { feeAmount: "", feeReceiver: "", isInBps: false },
              route: [[{ pool: "fixture", nested: { braces: "{}" } }]],
            },
            routerAddress: kyberRouter,
          },
        });
      }
      if (url.pathname === "/base/api/v1/route/build") {
        kyberRequestCount += 1;
        const body = (await request.json()) as {
          sender: Address;
          routeSummary: { amountIn: string };
        };
        const amountIn = BigInt(body.routeSummary.amountIn);
        return Response.json({
          code: 0,
          data: {
            amountIn: amountIn.toString(),
            routerAddress: kyberRouter,
            transactionValue: "0",
            data: kyberCalldata({
              sender: body.sender,
              amountIn,
              minAmountOut: 2_000_000n,
            }),
          },
        });
      }
      if (url.pathname === "/api/v2/collections/test-collection/stats") {
        if (request.headers.get("x-api-key") !== "opensea-secret") {
          return new Response("unauthorized", { status: 401 });
        }
        return Response.json({
          total: { floor_price: 0.01, floor_price_symbol: "ETH" },
        });
      }
      if (url.pathname === "/api/v2/drops/test-drop/mint") {
        if (request.headers.get("x-api-key") !== "opensea-secret") {
          return new Response("unauthorized", { status: 401 });
        }
        const body = (await request.json()) as {
          minter: Address;
          quantity: number;
        };
        return Response.json({
          chain: "base",
          to: seaDropAddress,
          data: encodeFunctionData({
            abi: seaDropMintAbi,
            functionName: "mintPublic",
            args: [
              nftAddress,
              feeRecipient,
              body.minter,
              BigInt(body.quantity),
            ],
          }),
          value: `0x${(1_000_000_000_000_000n * BigInt(body.quantity)).toString(16)}`,
        });
      }
      if (url.pathname === "/x402/gift-cards/search") {
        if (request.headers.get("x-access-token") !== "bitrefill-secret") {
          return new Response("unauthorized", { status: 401 });
        }
        return Response.json({
          products: [{ slug: "test-card", name: "Test Card" }],
        });
      }
      if (url.pathname === "/x402/products/detail") {
        if (request.headers.get("x-access-token") !== "bitrefill-secret") {
          return new Response("unauthorized", { status: 401 });
        }
        return Response.json({
          slug: "test-card",
          in_stock: true,
          currency: "USD",
        });
      }
      if (url.pathname.startsWith("/v1/health/")) {
        return Response.json({ success: true, data: { healthFactor: 2.5 } });
      }
      if (url.pathname === "/user-data") {
        return Response.json({
          positions: [
            {
              trader: url.searchParams.get("trader"),
              pairIndex: 0,
              index: 0,
              buy: true,
              collateral: "100000000",
              leverage: "100000000000",
              openPrice: "1000000000000000",
              tp: "1200000000000000",
              sl: "900000000000000",
              liquidationPrice: "850000000000000",
              rolloverFee: "1000",
              lossProtection: "0",
              openedAt: 1_757_000_000,
              isPnl: false,
              isOneCT: false,
            },
          ],
          limitOrders: [
            {
              trader: url.searchParams.get("trader"),
              pairIndex: 1,
              index: 2,
              buy: false,
              block: 35_961_058,
              collateral: "50000000",
              positionSize: "500000000",
              price: "20000000000000",
              leverage: "100000000000",
              tp: "18000000000000",
              sl: "22000000000000",
              slippageP: "10000000000",
              executionFee: "0",
              liquidationPrice: "22500000000000",
              limitOrderType: 0,
              isOneCT: false,
            },
          ],
        });
      }
      if (url.pathname === "/v2/trade/open") {
        const trader = url.searchParams.get("trader") as Address;
        const orderTypes = {
          market: 0,
          stop_limit: 1,
          limit: 2,
          market_pnl: 3,
        } as const;
        const orderType = url.searchParams.get(
          "orderType",
        ) as keyof typeof orderTypes;
        const data = encodeFunctionData({
          abi: avantisTradingAbi,
          functionName: "openTrade",
          args: [
            {
              trader,
              pairIndex: BigInt(url.searchParams.get("pairIndex") ?? "0"),
              index: 0n,
              initialPosToken: 0n,
              positionSizeUSDC: parseUnits(
                url.searchParams.get("collateralUsdc") ?? "0",
                6,
              ),
              openPrice: parseUnits(
                url.searchParams.get("openPrice") ?? "0",
                10,
              ),
              buy: url.searchParams.get("side") === "long",
              leverage: parseUnits(url.searchParams.get("leverage") ?? "0", 10),
              tp: parseUnits(url.searchParams.get("takeProfit") ?? "0", 10),
              sl: parseUnits(url.searchParams.get("stopLoss") ?? "0", 10),
              timestamp: 0n,
            },
            orderTypes[orderType],
            parseUnits(url.searchParams.get("slippagePercent") ?? "0", 10),
          ],
        });
        return Response.json({
          ok: true,
          data: {
            to: avantisTrading,
            from: trader,
            data,
            value: `0x${BigInt(url.searchParams.get("executionFeeWei") ?? "0").toString(16)}`,
            chainId: 8453,
            description: "fixture trade",
          },
        });
      }
      return new Response("not found", { status: 404 });
    },
  });
}

const localFetch: HttpFetch = (input, init) =>
  fetch(input, {
    ...init,
    tls: { rejectUnauthorized: false },
  } as BunFetchRequestInit);

const resolveRequirement: ResolveRequirement = ({ requirement }) => {
  if (requirement.path.toLowerCase() === "x-api-key") return "opensea-secret";
  if (requirement.path.toLowerCase() === "x-access-token")
    return "bitrefill-secret";
  throw new Error(`Unexpected requirement: ${requirement.path}`);
};

const authorizeRequest: AuthorizeRequest = ({ completedRequest }) => {
  if (new URL(completedRequest.url).origin !== serviceOrigin)
    throw new Error("origin denied");
};

async function deploy(parameters: {
  walletClient: ReturnType<typeof createWalletClient>;
  publicClient: ReturnType<typeof createPublicClient>;
  abi: Abi;
  bytecode: Hex;
  args?: readonly unknown[];
}): Promise<Address> {
  const hash = await parameters.walletClient.deployContract({
    account,
    abi: parameters.abi,
    bytecode: parameters.bytecode,
    chain: foundry,
    args: parameters.args ?? [],
  });
  const receipt = await parameters.publicClient.waitForTransactionReceipt({
    hash,
  });
  if (receipt.contractAddress == null)
    throw new Error("Deployment returned no address");
  return receipt.contractAddress;
}

async function resolve(parameters: {
  to: Address;
  abi: Abi;
  functionName: string;
  data: Hex;
}) {
  const publicClient = createPublicClient({
    chain: foundry,
    transport: http(rpcUrl),
  });
  const result = await resolveCall({
    call: { to: parameters.to, data: parameters.data },
    ethCall: async (call) => (await publicClient.call(call)).data ?? "0x",
    resolveRequirement,
    authorizeRequest,
    fetch: localFetch,
  });
  return decodeFunctionResult({
    abi: parameters.abi,
    functionName: parameters.functionName,
    data: result,
  });
}

async function loadDescriptor(parameters: {
  address: Address;
  abi: Abi;
  functionName: "queryDescriptor" | "actionDescriptor";
  id: Hex;
}): Promise<ApplicationDescriptor> {
  const publicClient = createPublicClient({
    chain: foundry,
    transport: http(rpcUrl),
  });
  const value = (await publicClient.readContract({
    address: parameters.address,
    abi: parameters.abi,
    functionName: parameters.functionName,
    args: [parameters.id],
  })) as Hex;
  return parseApplicationDescriptor(value);
}

beforeAll(async () => {
  const build = Bun.spawnSync(["forge", "build"], {
    stdout: "pipe",
    stderr: "pipe",
  });
  if (build.exitCode !== 0) throw new Error(build.stderr.toString());
  const certificate = createCertificate();
  server = startServer(certificate);
  serviceOrigin = `https://127.0.0.1:${server.port}`;

  const port = reservePort();
  rpcUrl = `http://127.0.0.1:${port}`;
  anvil = Bun.spawn([
    "anvil",
    "--port",
    String(port),
    "--quiet",
    "--disable-code-size-limit",
  ]);
  await waitForAnvil();

  const mockToken = artifactSchema.parse(
    await Bun.file("out/SelectedAppMocks.sol/SelectedAppMockToken.json").json(),
  );
  await rpc("anvil_setCode", [weth, mockToken.deployedBytecode.object]);
  await rpc("anvil_setCode", [usdc, mockToken.deployedBytecode.object]);

  const publicClient = createPublicClient({
    chain: foundry,
    transport: http(rpcUrl),
  });
  const walletClient = createWalletClient({
    account,
    chain: foundry,
    transport: http(rpcUrl),
  });
  const mockSeaDrop = artifactSchema.parse(
    await Bun.file(
      "out/SelectedAppMocks.sol/SelectedAppMockSeaDrop.json",
    ).json(),
  );
  const mockNft = artifactSchema.parse(
    await Bun.file("out/SelectedAppMocks.sol/SelectedAppMockNft.json").json(),
  );
  seaDropAddress = await deploy({
    walletClient,
    publicClient,
    abi: mockSeaDrop.abi as Abi,
    bytecode: mockSeaDrop.bytecode.object as Hex,
  });
  nftAddress = await deploy({
    walletClient,
    publicClient,
    abi: mockNft.abi as Abi,
    bytecode: mockNft.bytecode.object as Hex,
  });

  const kyber = artifactSchema.parse(
    await Bun.file(
      "out/KyberSwapApplicationAdapter.sol/KyberSwapApplicationAdapter.json",
    ).json(),
  );
  kyberAbi = kyber.abi as Abi;
  kyberAddress = await deploy({
    walletClient,
    publicClient,
    abi: kyberAbi,
    bytecode: kyber.bytecode.object as Hex,
    args: [serviceOrigin],
  });

  const openSea = artifactSchema.parse(
    await Bun.file(
      "out/OpenSeaApplicationAdapter.sol/OpenSeaApplicationAdapter.json",
    ).json(),
  );
  openSeaAbi = openSea.abi as Abi;
  openSeaAddress = await deploy({
    walletClient,
    publicClient,
    abi: openSeaAbi,
    bytecode: openSea.bytecode.object as Hex,
    args: [serviceOrigin, seaDropAddress],
  });

  const bitrefill = artifactSchema.parse(
    await Bun.file(
      "out/BitrefillApplicationAdapter.sol/BitrefillApplicationAdapter.json",
    ).json(),
  );
  bitrefillAbi = bitrefill.abi as Abi;
  bitrefillAddress = await deploy({
    walletClient,
    publicClient,
    abi: bitrefillAbi,
    bytecode: bitrefill.bytecode.object as Hex,
    args: [serviceOrigin],
  });

  const aerodrome = artifactSchema.parse(
    await Bun.file(
      "out/AerodromeApplicationAdapter.sol/AerodromeApplicationAdapter.json",
    ).json(),
  );
  aerodromeAbi = aerodrome.abi as Abi;
  aerodromeAddress = await deploy({
    walletClient,
    publicClient,
    abi: aerodromeAbi,
    bytecode: aerodrome.bytecode.object as Hex,
  });

  const moonwell = artifactSchema.parse(
    await Bun.file(
      "out/MoonwellApplicationAdapter.sol/MoonwellApplicationAdapter.json",
    ).json(),
  );
  moonwellAbi = moonwell.abi as Abi;
  moonwellAddress = await deploy({
    walletClient,
    publicClient,
    abi: moonwellAbi,
    bytecode: moonwell.bytecode.object as Hex,
    args: [serviceOrigin],
  });

  const avantis = artifactSchema.parse(
    await Bun.file(
      "out/AvantisApplicationAdapter.sol/AvantisApplicationAdapter.json",
    ).json(),
  );
  const avantisActionCodec = artifactSchema.parse(
    await Bun.file("out/AvantisActionCodec.sol/AvantisActionCodec.json").json(),
  );
  const avantisRequestCodec = artifactSchema.parse(
    await Bun.file(
      "out/AvantisRequestCodec.sol/AvantisRequestCodec.json",
    ).json(),
  );
  const actionCodecAddress = await deploy({
    walletClient,
    publicClient,
    abi: avantisActionCodec.abi as Abi,
    bytecode: avantisActionCodec.bytecode.object as Hex,
  });
  const requestCodecAddress = await deploy({
    walletClient,
    publicClient,
    abi: avantisRequestCodec.abi as Abi,
    bytecode: avantisRequestCodec.bytecode.object as Hex,
  });
  avantisAbi = avantis.abi as Abi;
  avantisAddress = await deploy({
    walletClient,
    publicClient,
    abi: avantisAbi,
    bytecode: avantis.bytecode.object as Hex,
    args: [
      serviceOrigin,
      serviceOrigin,
      actionCodecAddress,
      requestCodecAddress,
    ],
  });
}, 30_000);

afterAll(() => {
  server?.stop(true);
  anvil?.kill();
  if (temporaryDirectory !== undefined)
    rmSync(temporaryDirectory, { recursive: true, force: true });
});

describe("selected application adapters", () => {
  test("validates every published descriptor", async () => {
    for (const capability of [
      [aerodromeAddress, aerodromeAbi, "queryDescriptor", "aerodrome.pool"],
      [
        aerodromeAddress,
        aerodromeAbi,
        "queryDescriptor",
        "aerodrome.poolState",
      ],
      [
        aerodromeAddress,
        aerodromeAbi,
        "queryDescriptor",
        "aerodrome.lpPosition",
      ],
      [
        aerodromeAddress,
        aerodromeAbi,
        "queryDescriptor",
        "aerodrome.swapQuote.exactInput",
      ],
      [
        aerodromeAddress,
        aerodromeAbi,
        "actionDescriptor",
        "aerodrome.swap.exactInput",
      ],
      [moonwellAddress, moonwellAbi, "queryDescriptor", "moonwell.positions"],
      [moonwellAddress, moonwellAbi, "queryDescriptor", "moonwell.health"],
      [moonwellAddress, moonwellAbi, "queryDescriptor", "moonwell.market"],
      [moonwellAddress, moonwellAbi, "queryDescriptor", "moonwell.position"],
      [moonwellAddress, moonwellAbi, "actionDescriptor", "moonwell.supply"],
      [kyberAddress, kyberAbi, "actionDescriptor", "kyberswap.swap.exactInput"],
      [avantisAddress, avantisAbi, "queryDescriptor", "avantis.positions"],
      [avantisAddress, avantisAbi, "actionDescriptor", "avantis.trade.open"],
      [avantisAddress, avantisAbi, "actionDescriptor", "avantis.trade.close"],
      [avantisAddress, avantisAbi, "actionDescriptor", "avantis.limit.cancel"],
      [avantisAddress, avantisAbi, "actionDescriptor", "avantis.margin.update"],
      [avantisAddress, avantisAbi, "actionDescriptor", "avantis.limit.update"],
      [avantisAddress, avantisAbi, "actionDescriptor", "avantis.delegate.set"],
      [
        avantisAddress,
        avantisAbi,
        "actionDescriptor",
        "avantis.delegate.remove",
      ],
      [
        openSeaAddress,
        openSeaAbi,
        "queryDescriptor",
        "opensea.collection.stats",
      ],
      [
        openSeaAddress,
        openSeaAbi,
        "actionDescriptor",
        "opensea.drop.mint.public",
      ],
      [
        bitrefillAddress,
        bitrefillAbi,
        "queryDescriptor",
        "bitrefill.catalog.search",
      ],
      [
        bitrefillAddress,
        bitrefillAbi,
        "queryDescriptor",
        "bitrefill.product.detail",
      ],
    ] as const) {
      const descriptor = await loadDescriptor({
        address: capability[0],
        abi: capability[1],
        functionName: capability[2],
        id: keccak256(stringToHex(capability[3])),
      });
      expect(descriptor.name).toBe(capability[3]);
    }
  });

  test("uses shared descriptors across all six adapters", async () => {
    const aerodrome = await loadDescriptor({
      address: aerodromeAddress,
      abi: aerodromeAbi,
      functionName: "actionDescriptor",
      id: keccak256(stringToHex("aerodrome.swap.exactInput")),
    });
    expect(
      encodeDescriptorParameters({
        descriptor: aerodrome,
        values: {
          parameters: {
            pool: aerodromeWethUsdcPool,
            tokenIn: weth,
            tokenOut: usdc,
            amountIn: 1_000_000_000_000_000n,
            maxSlippageBps: 50,
            deadline: BigInt(Math.floor(Date.now() / 1000) + 300),
          },
        },
      }),
    ).toStartWith("0x");

    const moonwell = await loadDescriptor({
      address: moonwellAddress,
      abi: moonwellAbi,
      functionName: "queryDescriptor",
      id: keccak256(stringToHex("moonwell.health")),
    });
    if (moonwell.kind !== "query")
      throw new Error("Expected Moonwell query descriptor");
    const moonwellCall = encodeFunctionData({
      abi: moonwellAbi,
      functionName: "query",
      args: [
        keccak256(stringToHex("moonwell.health")),
        encodeDescriptorParameters({
          descriptor: moonwell,
          values: { account: account.address },
        }),
      ],
    });
    const moonwellResult = (await resolve({
      to: moonwellAddress,
      abi: moonwellAbi,
      functionName: "query",
      data: moonwellCall,
    })) as Hex;
    const decodedMoonwell = decodeDescriptorResult({
      descriptor: moonwell,
      data: moonwellResult,
    });
    expect((decodedMoonwell.result as { status: number }).status).toBe(200);

    for (const candidate of [
      {
        address: kyberAddress,
        abi: kyberAbi,
        functionName: "actionDescriptor" as const,
        id: keccak256(stringToHex("kyberswap.swap.exactInput")),
        name: "kyberswap.swap.exactInput",
      },
      {
        address: openSeaAddress,
        abi: openSeaAbi,
        functionName: "actionDescriptor" as const,
        id: keccak256(stringToHex("opensea.drop.mint.public")),
        name: "opensea.drop.mint.public",
      },
      {
        address: bitrefillAddress,
        abi: bitrefillAbi,
        functionName: "queryDescriptor" as const,
        id: keccak256(stringToHex("bitrefill.catalog.search")),
        name: "bitrefill.catalog.search",
      },
    ]) {
      const descriptor = await loadDescriptor(candidate);
      expect(descriptor.name).toBe(candidate.name);
      expect(descriptor.version).toBe("0.1");
    }
  });

  test("resolves KyberSwap quote and build requests recursively", async () => {
    const requestsBefore = kyberRequestCount;
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
    const descriptor = await loadDescriptor({
      address: kyberAddress,
      abi: kyberAbi,
      functionName: "actionDescriptor",
      id: keccak256(stringToHex("kyberswap.swap.exactInput")),
    });
    const data = encodeFunctionData({
      abi: kyberAbi,
      functionName: "prepare",
      args: [
        keccak256(stringToHex("kyberswap.swap.exactInput")),
        account.address,
        encodeDescriptorParameters({
          descriptor,
          values: {
            parameters: {
              tokenIn: weth,
              tokenOut: usdc,
              amountIn: 1_000_000_000_000_000n,
              minAmountOut: 2_000_000n,
              slippageBps: 50,
              deadline,
            },
          },
        }),
      ],
    });
    const prepared = (await resolve({
      to: kyberAddress,
      abi: kyberAbi,
      functionName: "prepare",
      data,
    })) as {
      calls: readonly { target: Address; value: bigint; data: Hex }[];
      validUntil: bigint;
    };

    expect(kyberRequestCount - requestsBefore).toBe(2);
    expect(prepared.calls).toHaveLength(2);
    expect(prepared.calls[1]?.target.toLowerCase()).toBe(
      kyberRouter.toLowerCase(),
    );
    expect(prepared.validUntil).toBe(deadline);
  });

  test("resolves authenticated OpenSea stats and public mint", async () => {
    const statsDescriptor = await loadDescriptor({
      address: openSeaAddress,
      abi: openSeaAbi,
      functionName: "queryDescriptor",
      id: keccak256(stringToHex("opensea.collection.stats")),
    });
    if (statsDescriptor.kind !== "query")
      throw new Error("Expected OpenSea query descriptor");
    const statsData = encodeFunctionData({
      abi: openSeaAbi,
      functionName: "query",
      args: [
        keccak256(stringToHex("opensea.collection.stats")),
        encodeDescriptorParameters({
          descriptor: statsDescriptor,
          values: { slug: "test-collection" },
        }),
      ],
    });
    const stats = (await resolve({
      to: openSeaAddress,
      abi: openSeaAbi,
      functionName: "query",
      data: statsData,
    })) as Hex;
    const decodedStats = decodeDescriptorResult({
      descriptor: statsDescriptor,
      data: stats,
    });
    expect(
      new TextDecoder().decode(
        Buffer.from(
          (decodedStats.result as { body: Hex }).body.slice(2),
          "hex",
        ),
      ),
    ).toContain("floor_price");

    const mintDescriptor = await loadDescriptor({
      address: openSeaAddress,
      abi: openSeaAbi,
      functionName: "actionDescriptor",
      id: keccak256(stringToHex("opensea.drop.mint.public")),
    });
    const mintData = encodeFunctionData({
      abi: openSeaAbi,
      functionName: "prepare",
      args: [
        keccak256(stringToHex("opensea.drop.mint.public")),
        account.address,
        encodeDescriptorParameters({
          descriptor: mintDescriptor,
          values: {
            parameters: {
              slug: "test-drop",
              nftContract: nftAddress,
              quantity: 2,
              maxTotalValue: 2_000_000_000_000_000n,
            },
          },
        }),
      ],
    });
    const prepared = (await resolve({
      to: openSeaAddress,
      abi: openSeaAbi,
      functionName: "prepare",
      data: mintData,
    })) as {
      calls: readonly { target: Address; value: bigint; data: Hex }[];
      validUntil: bigint;
    };
    expect(prepared.calls).toHaveLength(1);
    expect(prepared.calls[0]?.target.toLowerCase()).toBe(
      seaDropAddress.toLowerCase(),
    );
    expect(prepared.calls[0]?.value).toBe(2_000_000_000_000_000n);
  });

  test("resolves authenticated Bitrefill catalog queries without actions", async () => {
    for (const candidate of [
      {
        queryId: "bitrefill.catalog.search",
        values: {
          parameters: { kind: "GIFT_CARD", query: "test card", country: "US" },
        },
        expected: "Test Card",
      },
      {
        queryId: "bitrefill.product.detail",
        values: { slug: "test-card" },
        expected: "in_stock",
      },
    ]) {
      const id = keccak256(stringToHex(candidate.queryId));
      const descriptor = await loadDescriptor({
        address: bitrefillAddress,
        abi: bitrefillAbi,
        functionName: "queryDescriptor",
        id,
      });
      if (descriptor.kind !== "query")
        throw new Error("Expected Bitrefill query descriptor");
      const data = encodeFunctionData({
        abi: bitrefillAbi,
        functionName: "query",
        args: [
          id,
          encodeDescriptorParameters({
            descriptor,
            values: candidate.values,
          }),
        ],
      });
      const semanticResult = (await resolve({
        to: bitrefillAddress,
        abi: bitrefillAbi,
        functionName: "query",
        data,
      })) as Hex;
      const decoded = decodeDescriptorResult({
        descriptor,
        data: semanticResult,
      });
      const result = decoded.result as {
        status: number;
        sensitive: boolean;
        body: Hex;
      };
      expect(result.status).toBe(200);
      expect(result.sensitive).toBe(false);
      expect(
        new TextDecoder().decode(Buffer.from(result.body.slice(2), "hex")),
      ).toContain(candidate.expected);
    }
  });

  test("resolves Avantis positions and validated open-trade calldata", async () => {
    const positionsId = keccak256(stringToHex("avantis.positions"));
    const positionsDescriptor = await loadDescriptor({
      address: avantisAddress,
      abi: avantisAbi,
      functionName: "queryDescriptor",
      id: positionsId,
    });
    if (positionsDescriptor.kind !== "query")
      throw new Error("Expected Avantis query descriptor");
    const positionsResult = (await resolve({
      to: avantisAddress,
      abi: avantisAbi,
      functionName: "query",
      data: encodeFunctionData({
        abi: avantisAbi,
        functionName: "query",
        args: [
          positionsId,
          encodeDescriptorParameters({
            descriptor: positionsDescriptor,
            values: { account: account.address },
          }),
        ],
      }),
    })) as Hex;
    const positions = decodeDescriptorResult({
      descriptor: positionsDescriptor,
      data: positionsResult,
      inputValues: { account: account.address },
    }) as {
      positions: readonly {
        trader: Address;
        pairIndex: bigint;
        collateral: bigint;
        liquidationPrice: bigint;
      }[];
      limitOrders: readonly {
        trader: Address;
        pairIndex: bigint;
        index: bigint;
        price: bigint;
      }[];
    };
    expect(positions.positions).toHaveLength(1);
    expect(positions.positions[0]?.trader.toLowerCase()).toBe(
      account.address.toLowerCase(),
    );
    expect(positions.positions[0]?.pairIndex).toBe(0n);
    expect(positions.positions[0]?.collateral).toBe(100_000_000n);
    expect(positions.positions[0]?.liquidationPrice).toBe(850_000_000_000_000n);
    expect(positions.limitOrders).toHaveLength(1);
    expect(positions.limitOrders[0]?.pairIndex).toBe(1n);
    expect(positions.limitOrders[0]?.index).toBe(2n);
    expect(positions.limitOrders[0]?.price).toBe(20_000_000_000_000n);

    const actionId = keccak256(stringToHex("avantis.trade.open"));
    const actionDescriptor = await loadDescriptor({
      address: avantisAddress,
      abi: avantisAbi,
      functionName: "actionDescriptor",
      id: actionId,
    });
    const prepared = (await resolve({
      to: avantisAddress,
      abi: avantisAbi,
      functionName: "prepare",
      data: encodeFunctionData({
        abi: avantisAbi,
        functionName: "prepare",
        args: [
          actionId,
          account.address,
          encodeDescriptorParameters({
            descriptor: actionDescriptor,
            values: {
              parameters: {
                pairIndex: 0,
                isLong: true,
                orderType: "LIMIT",
                collateralUsdc: 100_000_000n,
                leverage: 100_000_000_000n,
                slippagePercent: 10_000_000_000n,
                openPrice: 1_000_000_000_000_000n,
                takeProfit: 1_200_000_000_000_000n,
                stopLoss: 900_000_000_000_000n,
                executionFeeWei: 350_000_000_000_000n,
              },
            },
          }),
        ],
      }),
    })) as {
      calls: readonly { target: Address; value: bigint; data: Hex }[];
      validUntil: bigint;
    };
    expect(prepared.calls).toHaveLength(2);
    expect(prepared.calls[1]?.target.toLowerCase()).toBe(
      avantisTrading.toLowerCase(),
    );
    expect(prepared.calls[1]?.value).toBe(350_000_000_000_000n);
    expect(prepared.validUntil).toBeGreaterThan(0n);
  });
});

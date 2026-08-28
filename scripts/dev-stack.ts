// Full local dev stack for the web console:
//   anvil (RPC) + HTTP fixture => cloudflared HTTPS tunnel + deployed adapters.
// Run: bun scripts/dev-stack.ts
import {
  encodeFunctionData,
  http,
  parseAbi,
  parseUnits,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import { createPublicClient, createWalletClient } from "viem";
import { spawn } from "bun";

const ANVIL_PORT = 18555;
const FIXTURE_PORT = 18600;
const rpcUrl = `http://127.0.0.1:${ANVIL_PORT}`;

const avantisTrading = "0x44914408af82bC9983bbb330e3578E1105e11d4e" as Address;
const usdc = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address;

const avantisTradingAbi = parseAbi([
  "function openTrade((address trader,uint256 pairIndex,uint256 index,uint256 initialPosToken,uint256 positionSizeUSDC,uint256 openPrice,bool buy,uint256 leverage,uint256 tp,uint256 sl,uint256 timestamp) trade,uint8 orderType,uint256 slippagePercent) payable returns (uint256 orderId)",
  "function closeTradeMarket(uint256 pairIndex,uint256 tradeIndex,uint256 collateralToClose,uint256 expectedPrice) payable",
  "function cancelOpenLimitOrder(uint256 pairIndex,uint256 orderIndex)",
  "function updateOpenLimitOrder(uint256 pairIndex,uint256 orderIndex,uint256 price,uint256 slippagePercent,uint256 takeProfit,uint256 stopLoss)",
  "function increasePositionSize((address trader,uint256 pairIndex,uint256 index,uint256 openPrice,uint256 additionalCollateralUsdc,uint256 leverage) request,uint256 slippagePercent)",
  "function updateMargin(uint256 pairIndex,uint256 tradeIndex,uint8 action,uint256 collateralUsdc,bytes[] priceUpdateData,uint8 priceSourcing) payable",
]);

const cors = (headers: Record<string, string> = {}) => ({
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  ...headers,
});

const ok = (data: unknown) =>
  Response.json({ ok: true, data }, { headers: cors() });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// --- 1. HTTP fixture -------------------------------------------------------
Bun.serve({
  hostname: "127.0.0.1",
  port: FIXTURE_PORT,
  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS")
      return new Response(null, { status: 204, headers: cors() });

    if (url.pathname === "/v2/positions") {
      const trader = url.searchParams.get("trader") as Address;
      return ok({
        trader,
        trades: [
          {
            trade: {
              trader,
              pairIndex: "0",
              index: "0",
              initialPosToken: "0",
              positionSizeUSDC: "100000000",
              openPrice: "40000000000000",
              buy: true,
              leverage: "100000000000",
              tp: "50000000000000",
              sl: "30000000000000",
              timestamp: "0",
            },
            tradeInfo: {
              openInterestUSDC: "1000000000",
              tpLastUpdated: "0",
              slLastUpdated: "0",
              beingMarketClosed: false,
              lossProtection: "0",
            },
            rolloverFee: "0",
            liquidationPrice: "35000000000000",
            isPnl: false,
            coinExposure: "0",
          },
        ],
        orders: [
          {
            order: {
              trader,
              pairIndex: "1",
              index: "0",
              positionSize: "50000000",
              buy: false,
              leverage: "50000000000",
              tp: "0",
              sl: "38000000000000",
              price: "36000000000000",
              slippageP: "10000000000",
              block: "35961058",
              executionFee: "0",
            },
            liquidationPrice: "37919600000000",
            orderType: 0,
            coinExposure: "0",
          },
        ],
      });
    }
    if (url.pathname === "/v2/meta") {
      return ok({
        chainId: 8453,
        addresses: { usdc, tradingRouter: avantisTrading },
        enums: {
          openOrderType: { market: 0, stop_limit: 1, limit: 2, market_pnl: 3 },
          priceSourcing: { HERMES: 0, PRO: 1 },
        },
        units: { price: "1e10", leverage: "1e10", slippagePercent: "1e10", usdc: "1e6" },
        defaults: { executionFeeWei: "0", slippagePercent: "1" },
      });
    }
    if (url.pathname === "/v2/pairs") {
      return ok([
        {
          index: 0,
          symbol: "ETH/USD",
          isPairListed: true,
          pairMinLevPosUSDC: 100,
          leverages: { minLeverage: 1, maxLeverage: 50 },
          pairOI: 364000.6,
          pairMaxOI: 10977839.38,
        },
      ]);
    }
    if (url.pathname.startsWith("/v2/pairs/")) {
      return ok({
        index: 0,
        symbol: "ETH/USD",
        isPairListed: true,
        pairMinLevPosUSDC: 100,
        leverages: { minLeverage: 1, maxLeverage: 50 },
        pairOI: 364000.6,
        pairMaxOI: 10977839.38,
      });
    }
    if (url.pathname === "/v2/trade/open") {
      const trader = url.searchParams.get("trader") as Address;
      const orderTypes = { market: 0, stop_limit: 1, limit: 2, market_pnl: 3 } as const;
      const orderType = url.searchParams.get("orderType") as keyof typeof orderTypes;
      const data = encodeFunctionData({
        abi: avantisTradingAbi,
        functionName: "openTrade",
        args: [
          {
            trader,
            pairIndex: BigInt(url.searchParams.get("pairIndex") ?? "0"),
            index: 0n,
            initialPosToken: 0n,
            positionSizeUSDC: parseUnits(url.searchParams.get("collateralUsdc") ?? "0", 6),
            openPrice: parseUnits(url.searchParams.get("openPrice") ?? "0", 10),
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
      return ok({
        to: avantisTrading,
        from: trader,
        data,
        value: `0x${BigInt(url.searchParams.get("executionFeeWei") ?? "0").toString(16)}`,
        chainId: 8453,
        description: "fixture open trade",
      });
    }
    if (url.pathname === "/v2/trade/close") {
      const trader = url.searchParams.get("trader") as Address;
      return ok({
        to: avantisTrading,
        from: trader,
        data: encodeFunctionData({
          abi: avantisTradingAbi,
          functionName: "closeTradeMarket",
          args: [
            BigInt(url.searchParams.get("pairIndex") ?? "0"),
            BigInt(url.searchParams.get("tradeIndex") ?? "0"),
            parseUnits(url.searchParams.get("collateralToCloseUsdc") ?? "0", 6),
            parseUnits(url.searchParams.get("expectedPrice") ?? "0", 10),
          ],
        }),
        value: `0x${BigInt(url.searchParams.get("executionFeeWei") ?? "0").toString(16)}`,
        chainId: 8453,
        description: "fixture close",
      });
    }
    if (url.pathname === "/v2/margin/update") {
      const trader = url.searchParams.get("trader") as Address;
      return ok({
        to: avantisTrading,
        from: trader,
        data: encodeFunctionData({
          abi: avantisTradingAbi,
          functionName: "updateMargin",
          args: [
            BigInt(url.searchParams.get("pairIndex") ?? "0"),
            BigInt(url.searchParams.get("tradeIndex") ?? "0"),
            url.searchParams.get("action") === "deposit" ? 0 : 1,
            parseUnits(url.searchParams.get("collateralUsdc") ?? "0", 6),
            ["0x1234"],
            Number(url.searchParams.get("priceSourcing") ?? "0"),
          ],
        }),
        value: `0x${BigInt(url.searchParams.get("oracleFeeWei") ?? "0").toString(16)}`,
        chainId: 8453,
        description: "fixture margin",
      });
    }
    if (url.pathname === "/v2/limit/cancel") {
      const trader = url.searchParams.get("trader") as Address;
      return ok({
        to: avantisTrading,
        from: trader,
        data: encodeFunctionData({
          abi: avantisTradingAbi,
          functionName: "cancelOpenLimitOrder",
          args: [
            BigInt(url.searchParams.get("pairIndex") ?? "0"),
            BigInt(url.searchParams.get("orderIndex") ?? "0"),
          ],
        }),
        value: "0x0",
        chainId: 8453,
        description: "fixture cancel",
      });
    }
    if (url.pathname.startsWith("/v1/positions/")) {
      return ok([{ market: "mUSDC", suppliedUsd: 100, collateralEnabled: true }]);
    }
    if (url.pathname.startsWith("/v1/health/")) {
      return ok({ healthFactor: 2.5 });
    }
    return new Response("not found", { status: 404, headers: cors() });
  },
});
console.log(`[fixture] http://127.0.0.1:${FIXTURE_PORT}`);

// --- 2. anvil --------------------------------------------------------------
spawn([
  "anvil",
  "--port",
  String(ANVIL_PORT),
  "--quiet",
  "--disable-code-size-limit",
  "--allow-origin",
  "*",
]);
for (let i = 0; i < 100; i += 1) {
  try {
    const res = await fetch(rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
    });
    if (res.ok) break;
  } catch {
    await sleep(50);
  }
}
console.log(`[anvil] ${rpcUrl} (chain 31337)`);

// --- 3. cloudflared HTTPS tunnel over the fixture ---------------------------
const logPath = "/tmp/opencode-devstack-cloudflared.log";
await Bun.write(logPath, "");
Bun.spawn(
  ["cloudflared", "tunnel", "--url", `http://127.0.0.1:${FIXTURE_PORT}`],
  { stdout: Bun.file(logPath), stderr: Bun.file(logPath) },
);
let tunnelUrl: string | undefined;
for (let i = 0; i < 120 && tunnelUrl === undefined; i += 1) {
  const text = (await Bun.file(logPath).text()).trim();
  const match = text.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
  if (match) tunnelUrl = match[0];
  else await sleep(250);
}
if (tunnelUrl === undefined) {
  console.error("[tunnel] could not establish a trycloudflare tunnel");
  process.exit(1);
}
console.log(`[tunnel] ${tunnelUrl}`);

// --- 4. deployments ----------------------------------------------------------
const account = privateKeyToAccount(
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
);
const publicClient = createPublicClient({ chain: foundry, transport: http(rpcUrl) });
const walletClient = createWalletClient({ account, chain: foundry, transport: http(rpcUrl) });

async function deploy(file: string, args: readonly unknown[] = []): Promise<Address> {
  const artifact = await Bun.file(file).json();
  const hash = await walletClient.deployContract({
    account,
    abi: artifact.abi,
    bytecode: artifact.bytecode.object,
    args,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.contractAddress === null) throw new Error("no contract address");
  return receipt.contractAddress;
}

const mockToken = await Bun.file("out/SelectedAppMocks.sol/SelectedAppMockToken.json").json();
await publicClient.request({
  method: "anvil_setCode",
  params: [usdc, mockToken.deployedBytecode.object],
});
console.log(`[usdc mock] etched at ${usdc}`);

const aerodrome = await deploy(
  "out/AerodromeApplicationAdapter.sol/AerodromeApplicationAdapter.json",
);
const moonwell = await deploy(
  "out/MoonwellApplicationAdapter.sol/MoonwellApplicationAdapter.json",
  [tunnelUrl],
);
const avantis = await deploy(
  "out/AvantisApplicationAdapter.sol/AvantisApplicationAdapter.json",
  [tunnelUrl],
);

console.log("=== DEV STACK READY ===");
console.log(
  JSON.stringify({ rpcUrl, tunnelUrl, useAsExternalOrigin: tunnelUrl, aerodrome, moonwell, avantis }),
);

// Keep the process alive so anvil and the tunnel stay up.
await new Promise(() => {});
import { createPublicClient, http } from "viem";

const addr = "0xfa5725214419f9688133841f67e10c4783d17b26";
const chains: Record<number, string> = {
 8453: "Base", 42161: "Arbitrum", 10: "Optimism", 1: "Ethereum", 137: "Polygon",
 324: "zkSync", 534352: "Scroll", 5000: "Mantle", 84531:"Base Goerli", 11155111:"Sepolia", 84532:"Base Sepolia",
 34443:"Mode", 204:"opBNB", 30:"RSK", 4689:"IoTeX", 272:"zkSyncSepolia", 2442:"PolygonZkEVM",
};
for (const [id, name] of Object.entries(chains)) {
  try {
    const client = createPublicClient({ transport: http(`https://evm.stupidtech.net/v1/${id}`) });
    const code = await client.request({ method: "eth_getCode", params: [addr, "latest"] });
    console.log(`${id} (${name}): bytecode length = ${code && code.length ? code.length : 0}`);
  } catch (e) {
    console.log(`${id} (${name}): ERROR ${describe(e)}`);
  }
}
function describe(e: unknown){ const m=(e as Error).message; return m.length>120?m.slice(0,120):m; }

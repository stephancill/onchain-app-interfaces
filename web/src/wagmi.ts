import { createConfig, http } from "wagmi";
import { base, mainnet, sepolia } from "wagmi/chains";

export const config = createConfig({
  chains: [base, mainnet, sepolia],
  transports: {
    [base.id]: http(),
    [mainnet.id]: http(),
    [sepolia.id]: http(),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}

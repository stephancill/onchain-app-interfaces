import { useMutation, useQuery } from "@tanstack/react-query";
import { parseAsBoolean, parseAsString, useQueryStates } from "nuqs";
import { useState } from "react";
import {
  createPublicClient,
  decodeFunctionResult,
  defineChain,
  encodeFunctionData,
  getAddress,
  http,
  isAddress,
  type Address,
  type Hex,
} from "viem";
import {
  useConnect,
  useConnection,
  useConnectors,
  useDisconnect,
  useSendCalls,
  useSwitchChain,
  useWaitForCallsStatus,
} from "wagmi";
import { z } from "zod";

import {
  decodeDescriptorResult,
  encodeDescriptorParameters,
  parseApplicationDescriptor,
  resolveCall,
  type ApplicationDescriptor,
  type DescriptorField,
  type QueryDescriptor,
} from "../../src/client/index.ts";
import skillUrl from "../../skills/onchain-app-interfaces/SKILL.md?url";

const queryAbi = [
  {
    type: "function",
    name: "queries",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "queryIds", type: "bytes32[]" }],
  },
  {
    type: "function",
    name: "queryDescriptor",
    stateMutability: "view",
    inputs: [{ name: "queryId", type: "bytes32" }],
    outputs: [{ name: "descriptor", type: "bytes" }],
  },
  {
    type: "function",
    name: "query",
    stateMutability: "view",
    inputs: [
      { name: "queryId", type: "bytes32" },
      { name: "parameters", type: "bytes" },
    ],
    outputs: [{ name: "result", type: "bytes" }],
  },
] as const;

const actionAbi = [
  {
    type: "function",
    name: "actions",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "actionIds", type: "bytes32[]" }],
  },
  {
    type: "function",
    name: "actionDescriptor",
    stateMutability: "view",
    inputs: [{ name: "actionId", type: "bytes32" }],
    outputs: [{ name: "descriptor", type: "bytes" }],
  },
  {
    type: "function",
    name: "prepare",
    stateMutability: "view",
    inputs: [
      { name: "actionId", type: "bytes32" },
      { name: "account", type: "address" },
      { name: "parameters", type: "bytes" },
    ],
    outputs: [
      {
        name: "preparedAction",
        type: "tuple",
        components: [
          {
            name: "calls",
            type: "tuple[]",
            components: [
              { name: "target", type: "address" },
              { name: "value", type: "uint256" },
              { name: "data", type: "bytes" },
            ],
          },
          { name: "validUntil", type: "uint256" },
        ],
      },
    ],
  },
] as const;

const targetSchema = z.object({
  chainId: z.coerce.number().int().positive(),
  rpcUrl: z
    .url()
    .refine((value) => ["http:", "https:"].includes(new URL(value).protocol), {
      message: "RPC URL must use HTTP or HTTPS",
    }),
  address: z.string().refine(isAddress, "Enter a valid adapter address"),
});

const valuesSchema = z.record(z.string(), z.unknown());
const requirementValuesSchema = z.record(z.string(), z.string());
const baseRpcUrl = "https://evm.stupidtech.net/v1/8453";
const aerodromeWethUsdcPool = "0xcDAC0d6c6C59727a65F871236188350531885C43";
const examples = [
  {
    name: "Aerodrome",
    chainId: "8453",
    rpcUrl: baseRpcUrl,
    address: "0x31cB53007f5fDECEAa84d43ad4E387A081E13f7b",
    externalOrigin: "",
  },
  {
    name: "Moonwell",
    chainId: "8453",
    rpcUrl: baseRpcUrl,
    address: "0x805E521b5BD349B02380DC0C81bcd75bDb374FD2",
    externalOrigin: "https://api.moonwell.fi",
  },
  {
    name: "Avantis",
    chainId: "8453",
    rpcUrl: baseRpcUrl,
    address: "0x53c8B42bf72C286e453D56F74831E9DFb975b0d6",
    externalOrigin:
      "https://core.avantisfi.com\nhttps://tx-builder.avantisfi.com",
  },
] as const;

type Target = z.infer<typeof targetSchema>;
type Capability = {
  id: Hex;
  descriptor: ApplicationDescriptor;
};
type LoadedInterface = {
  queries: Capability[];
  actions: Capability[];
  unsupported: string[];
};
type PreparedAction = {
  calls: readonly {
    target: Address;
    value: bigint;
    data: Hex;
  }[];
  validUntil: bigint;
};

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function jsonValue(value: unknown): string {
  return JSON.stringify(
    value,
    (_, item: unknown) => (typeof item === "bigint" ? item.toString() : item),
    2,
  );
}

function defaultFieldValue(field: DescriptorField, account?: Address): unknown {
  if (field.abiType === "tuple") {
    return Object.fromEntries(
      (field.components ?? []).map((component) => [
        component.name,
        defaultFieldValue(component, account),
      ]),
    );
  }
  if (field.abiType === "address") {
    return account ?? "0x0000000000000000000000000000000000000000";
  }
  if (field.abiType === "bool") return false;
  if (field.semanticType === "timestamp") {
    return String(Math.floor(Date.now() / 1000) + 60 * 60);
  }
  if (/^u?int/.test(field.abiType)) return field.minimum ?? "0";
  if (field.abiType.startsWith("bytes")) return "0x";
  return "";
}

function defaultValues(
  descriptor: ApplicationDescriptor,
  account?: Address,
): string {
  if (descriptor.name === "aerodrome.poolState") {
    return jsonValue({ pool: aerodromeWethUsdcPool });
  }
  if (descriptor.name === "aerodrome.lpPosition") {
    return jsonValue({
      pool: aerodromeWethUsdcPool,
      account: account ?? "0x0000000000000000000000000000000000000000",
    });
  }
  if (descriptor.name === "aerodrome.swapQuote.exactInput") {
    return jsonValue({
      pool: aerodromeWethUsdcPool,
      tokenIn: "0x4200000000000000000000000000000000000006",
      tokenOut: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      amountIn: "1000000000000000000",
    });
  }
  if (descriptor.name === "aerodrome.swap.exactInput") {
    return jsonValue({
      parameters: {
        pool: aerodromeWethUsdcPool,
        tokenIn: "0x4200000000000000000000000000000000000006",
        tokenOut: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        amountIn: "1000000000000000000",
        maxSlippageBps: "100",
        deadline: String(Math.floor(Date.now() / 1000) + 60 * 60),
      },
    });
  }
  if (descriptor.name === "moonwell.position.usdc") {
    return jsonValue({
      account: account ?? "0x0000000000000000000000000000000000000000",
    });
  }
  if (descriptor.name === "moonwell.positions") {
    return jsonValue({
      account: account ?? "0x0000000000000000000000000000000000000000",
    });
  }
  if (descriptor.name === "moonwell.health") {
    return jsonValue({
      account: account ?? "0x0000000000000000000000000000000000000000",
    });
  }
  if (descriptor.name === "moonwell.supply.usdc") {
    return jsonValue({
      parameters: {
        amount: "1000000",
        enableAsCollateral: false,
      },
    });
  }
  if (descriptor.name === "avantis.positions") {
    return jsonValue({
      account: account ?? "0x0000000000000000000000000000000000000000",
    });
  }
  if (descriptor.name === "avantis.markets") {
    return jsonValue({});
  }
  if (descriptor.name === "avantis.market") {
    return jsonValue({ pairIndex: "0" });
  }
  if (descriptor.name === "avantis.trade.open") {
    return jsonValue({
      parameters: {
        pairIndex: "0",
        isLong: true,
        orderType: "LIMIT",
        collateralUsdc: "100000000",
        leverage: "100000000000",
        slippagePercent: "10000000000",
        openPrice: "1000000000000000",
        takeProfit: "1200000000000000",
        stopLoss: "900000000000000",
        executionFeeWei: "350000000000000",
      },
    });
  }
  if (descriptor.name === "avantis.trade.close") {
    return jsonValue({
      parameters: {
        pairIndex: "0",
        tradeIndex: "0",
        collateralToCloseUsdc: "50000000",
        expectedPrice: "40000000000000",
        executionFeeWei: "350000000000000",
      },
    });
  }
  if (descriptor.name === "avantis.limit.cancel") {
    return jsonValue({ parameters: { pairIndex: "0", orderIndex: "0" } });
  }
  if (descriptor.name === "avantis.limit.update") {
    return jsonValue({
      parameters: {
        pairIndex: "0",
        orderIndex: "0",
        price: "40000000000000",
        slippagePercent: "10000000000",
        takeProfit: "50000000000000",
        stopLoss: "30000000000000",
      },
    });
  }
  if (descriptor.name === "avantis.position.increase") {
    return jsonValue({
      parameters: {
        pairIndex: "0",
        tradeIndex: "0",
        additionalCollateralUsdc: "25000000",
        leverage: "100000000000",
        openPrice: "40000000000000",
        slippagePercent: "10000000000",
      },
    });
  }
  if (descriptor.name === "avantis.margin.update") {
    return jsonValue({
      parameters: {
        pairIndex: "0",
        tradeIndex: "0",
        action: "DEPOSIT",
        collateralUsdc: "25000000",
        priceSourcing: "PRO",
        oracleFeeWei: "1",
      },
    });
  }
  if (descriptor.name === "avantis.account") {
    return jsonValue({
      account: account ?? "0x0000000000000000000000000000000000000000",
    });
  }
  return jsonValue(
    Object.fromEntries(
      descriptor.inputs.fields.map((field) => [
        field.name,
        defaultFieldValue(field, account),
      ]),
    ),
  );
}

function clientFor(target: Target) {
  return createPublicClient({
    chain: defineChain({
      id: target.chainId,
      name: `Chain ${target.chainId}`,
      nativeCurrency: { name: "Native", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [target.rpcUrl] } },
    }),
    transport: http(target.rpcUrl),
  });
}

async function loadInterface(target: Target): Promise<LoadedInterface> {
  const client = clientFor(target);
  const address = getAddress(target.address);
  const code = await client.getCode({ address });
  if (code === undefined || code === "0x")
    throw new Error("Adapter address has no bytecode");

  const [queryIdsResult, actionIdsResult] = await Promise.allSettled([
    client.readContract({ address, abi: queryAbi, functionName: "queries" }),
    client.readContract({ address, abi: actionAbi, functionName: "actions" }),
  ]);
  if (
    queryIdsResult.status === "rejected" &&
    actionIdsResult.status === "rejected"
  ) {
    throw new Error(
      "Contract exposes neither Application Queries nor Application Actions",
    );
  }

  const queryIds =
    queryIdsResult.status === "fulfilled" ? queryIdsResult.value : [];
  const actionIds =
    actionIdsResult.status === "fulfilled" ? actionIdsResult.value : [];
  const [queries, actions] = await Promise.all([
    Promise.all(
      queryIds.map(async (id) => {
        const value = await client.readContract({
          address,
          abi: queryAbi,
          functionName: "queryDescriptor",
          args: [id],
        });
        const descriptor = parseApplicationDescriptor(value);
        if (descriptor.kind !== "query")
          throw new Error(`${id} has a non-query descriptor`);
        return { id, descriptor };
      }),
    ),
    Promise.all(
      actionIds.map(async (id) => {
        const value = await client.readContract({
          address,
          abi: actionAbi,
          functionName: "actionDescriptor",
          args: [id],
        });
        const descriptor = parseApplicationDescriptor(value);
        if (descriptor.kind !== "action")
          throw new Error(`${id} has a non-action descriptor`);
        return { id, descriptor };
      }),
    ),
  ]);

  const unsupported = [
    ...(queryIdsResult.status === "rejected" ? ["Application Queries"] : []),
    ...(actionIdsResult.status === "rejected" ? ["Application Actions"] : []),
  ];
  return { queries, actions, unsupported };
}

function parseOrigins(value: string): Set<string> {
  return new Set(
    value
      .split("\n")
      .map((entry) => entry.trim())
      .filter(Boolean)
      .map((entry) => new URL(entry).origin),
  );
}

async function resolveInterfaceCall(parameters: {
  target: Target;
  data: Hex;
  requirementValues: Record<string, string>;
  allowedOrigins: Set<string>;
}): Promise<Hex> {
  const client = clientFor(parameters.target);
  const address = getAddress(parameters.target.address);
  return resolveCall({
    call: { to: address, data: parameters.data },
    ethCall: async (call) => (await client.call(call)).data ?? "0x",
    resolveRequirement: ({ requirement }) => {
      const key = `${requirement.location}:${requirement.path}`;
      const value = parameters.requirementValues[key];
      if (value === undefined)
        throw new Error(`Missing External Request value for ${key}`);
      return value;
    },
    authorizeRequest: ({ completedRequest }) => {
      const origin = new URL(completedRequest.url).origin;
      if (!parameters.allowedOrigins.has(origin)) {
        throw new Error(`External Request origin is not allowed: ${origin}`);
      }
    },
    maxRequests: 4,
    maxResponseBytes: 1_000_000,
  });
}

function CapabilityCard(parameters: {
  capability: Capability;
  target: Target;
  account?: Address;
  requirementValues: Record<string, string>;
  allowedOrigins: Set<string>;
}) {
  const { capability, target, account, requirementValues, allowedOrigins } =
    parameters;
  const [values, setValues] = useState(() =>
    defaultValues(capability.descriptor, account),
  );
  const [actionAccount, setActionAccount] = useState(account ?? "");
  const [executionError, setExecutionError] = useState<string>();
  const connection = useConnection();
  const sendCalls = useSendCalls();
  const switchChain = useSwitchChain();
  const callsStatus = useWaitForCallsStatus({
    id: sendCalls.data?.id ?? "",
    query: { enabled: sendCalls.data !== undefined },
  });
  const mutation = useMutation({
    mutationFn: async () => {
      const parsedValues = valuesSchema.parse(JSON.parse(values));
      const encodedParameters = encodeDescriptorParameters({
        descriptor: capability.descriptor,
        values: parsedValues,
      });

      if (capability.descriptor.kind === "query") {
        const data = encodeFunctionData({
          abi: queryAbi,
          functionName: "query",
          args: [capability.id, encodedParameters],
        });
        const raw = await resolveInterfaceCall({
          target,
          data,
          requirementValues,
          allowedOrigins,
        });
        const result = decodeFunctionResult({
          abi: queryAbi,
          functionName: "query",
          data: raw,
        });
        return {
          parameters: encodedParameters,
          result: decodeDescriptorResult({
            descriptor: capability.descriptor as QueryDescriptor,
            data: result,
          }),
        };
      }

      if (!isAddress(actionAccount))
        throw new Error("Enter an account for action preparation");
      const data = encodeFunctionData({
        abi: actionAbi,
        functionName: "prepare",
        args: [capability.id, getAddress(actionAccount), encodedParameters],
      });
      const raw = await resolveInterfaceCall({
        target,
        data,
        requirementValues,
        allowedOrigins,
      });
      return {
        parameters: encodedParameters,
        result: decodeFunctionResult({
          abi: actionAbi,
          functionName: "prepare",
          data: raw,
        }),
      };
    },
  });

  const descriptor = capability.descriptor;
  const preparedAction =
    descriptor.kind === "action" && mutation.data !== undefined
      ? (mutation.data.result as PreparedAction)
      : undefined;
  const atomicRequired =
    descriptor.kind === "action" &&
    descriptor.execution?.atomicity === "atomic-required";
  let executionBlockedReason: string | undefined;
  if (preparedAction !== undefined) {
    if (account === undefined)
      executionBlockedReason = "Connect a wallet to execute";
    else if (
      !isAddress(actionAccount) ||
      getAddress(actionAccount) !== account
    ) {
      executionBlockedReason =
        "Connected wallet must match the preparation account";
    } else if (![1, 8453, 11155111].includes(target.chainId)) {
      executionBlockedReason = `Wallet execution is not configured for chain ${target.chainId}`;
    } else if (
      preparedAction.validUntil !== 0n &&
      BigInt(Math.floor(Date.now() / 1000)) > preparedAction.validUntil
    ) {
      executionBlockedReason = "Prepared action has expired; prepare it again";
    }
  }

  async function executePreparedAction() {
    if (preparedAction === undefined || account === undefined) return;
    if (executionBlockedReason !== undefined) {
      setExecutionError(executionBlockedReason);
      return;
    }
    setExecutionError(undefined);
    sendCalls.reset();
    const chainId = target.chainId as 1 | 8453 | 11155111;
    try {
      if (connection.chainId !== chainId) {
        await switchChain.switchChainAsync({ chainId });
      }
      sendCalls.mutate({
        account,
        calls: preparedAction.calls.map((call) => ({
          to: call.target,
          value: call.value,
          data: call.data,
        })),
        chainId,
        forceAtomic: atomicRequired,
        experimental_fallback: !atomicRequired,
      });
    } catch (error) {
      setExecutionError(errorMessage(error));
    }
  }

  return (
    <article className="capability-card">
      <div className="capability-heading">
        <div>
          <span>{descriptor.kind}</span>
          <h3>{descriptor.name}</h3>
        </div>
        <code title={capability.id}>
          {capability.id.slice(0, 10)}...{capability.id.slice(-6)}
        </code>
      </div>
      {descriptor.description && <p>{descriptor.description}</p>}
      <dl className="metadata">
        <div>
          <dt>Provenance</dt>
          <dd>{descriptor.provenance?.type ?? "not declared"}</dd>
        </div>
        <div>
          <dt>Inputs</dt>
          <dd>{descriptor.inputs.fields.length}</dd>
        </div>
        {descriptor.kind === "action" && (
          <div>
            <dt>Atomicity</dt>
            <dd>{descriptor.execution?.atomicity ?? "not declared"}</dd>
          </div>
        )}
      </dl>
      <details>
        <summary>Descriptor</summary>
        <pre>{jsonValue(descriptor)}</pre>
      </details>
      {descriptor.kind === "action" && (
        <label>
          Preparation account
          <input
            value={actionAccount}
            onChange={(event) => setActionAccount(event.target.value)}
            placeholder="0x..."
            spellCheck={false}
          />
        </label>
      )}
      <label>
        Input values (JSON)
        <textarea
          value={values}
          onChange={(event) => setValues(event.target.value)}
          rows={Math.max(5, descriptor.inputs.fields.length * 2 + 2)}
          spellCheck={false}
        />
      </label>
      <button
        type="button"
        onClick={() => mutation.mutate()}
        disabled={mutation.isPending}
      >
        {mutation.isPending
          ? "Resolving..."
          : descriptor.kind === "query"
            ? "Run query"
            : "Prepare action"}
      </button>
      {mutation.error && (
        <p className="error">{errorMessage(mutation.error)}</p>
      )}
      {mutation.data && (
        <div className="result">
          <strong>
            {descriptor.kind === "query"
              ? "Semantic result"
              : "Prepared calls (not executed)"}
          </strong>
          <pre>{jsonValue(mutation.data)}</pre>
          {preparedAction !== undefined && (
            <>
              <button
                type="button"
                onClick={() => void executePreparedAction()}
                disabled={
                  sendCalls.isPending ||
                  switchChain.isPending ||
                  executionBlockedReason !== undefined
                }
              >
                {switchChain.isPending
                  ? "Switching network..."
                  : sendCalls.isPending
                    ? "Confirm in wallet..."
                    : "Execute with wallet"}
              </button>
              {executionBlockedReason && <p>{executionBlockedReason}</p>}
              {(executionError || sendCalls.error || callsStatus.error) && (
                <p className="error">
                  {executionError ??
                    errorMessage(sendCalls.error ?? callsStatus.error)}
                </p>
              )}
              {sendCalls.data && (
                <div>
                  <strong>Wallet bundle</strong>
                  <pre>
                    {jsonValue({
                      id: sendCalls.data.id,
                      status: callsStatus.data ?? "Submitted",
                    })}
                  </pre>
                </div>
              )}
            </>
          )}
        </div>
      )}
    </article>
  );
}

function WalletConnection() {
  const connection = useConnection();
  const connectors = useConnectors();
  const { connect, error } = useConnect();
  const { disconnect } = useDisconnect();

  if (connection.status === "connected") {
    return (
      <div className="wallet">
        <span>
          {connection.addresses[0]?.slice(0, 6)}...
          {connection.addresses[0]?.slice(-4)}
        </span>
        <button type="button" onClick={() => disconnect()}>
          Disconnect
        </button>
      </div>
    );
  }
  return (
    <div className="wallet">
      {connectors.map((connector) => (
        <button
          key={connector.uid}
          type="button"
          onClick={() => connect({ connector })}
        >
          Connect {connector.name}
        </button>
      ))}
      {error && <span className="error">{error.message}</span>}
    </div>
  );
}

function App() {
  const connection = useConnection();
  const walletConnected =
    connection.status === "connected" && connection.connector !== undefined;
  const account = walletConnected ? connection.addresses[0] : undefined;
  const [consoleState, setConsoleState] = useQueryStates({
    chainId: parseAsString.withDefault("8453"),
    rpcUrl: parseAsString.withDefault(baseRpcUrl),
    address: parseAsString.withDefault(examples[0].address),
    origins: parseAsString.withDefault(""),
    active: parseAsBoolean.withDefault(false),
  });
  const [targetError, setTargetError] = useState<string>();
  const [requirementText, setRequirementText] = useState("{}");
  const parsedTarget = targetSchema.safeParse(consoleState);
  const target =
    consoleState.active && parsedTarget.success
      ? { ...parsedTarget.data, address: getAddress(parsedTarget.data.address) }
      : undefined;

  const interfaceQuery = useQuery({
    queryKey: ["application-interface", target],
    queryFn: () => loadInterface(target!),
    enabled: target !== undefined,
    retry: false,
  });

  let requirementValues: Record<string, string> = {};
  let allowedOrigins = new Set<string>();
  let policyError: string | undefined;
  try {
    requirementValues = requirementValuesSchema.parse(
      JSON.parse(requirementText),
    );
    allowedOrigins = parseOrigins(consoleState.origins);
  } catch (error) {
    policyError = errorMessage(error);
  }

  async function submitTarget(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!parsedTarget.success) {
      setTargetError(
        parsedTarget.error.issues[0]?.message ??
          "Invalid adapter configuration",
      );
      return;
    }
    setTargetError(undefined);
    if (consoleState.active) await interfaceQuery.refetch();
    else await setConsoleState({ active: true });
  }

  async function loadExample(example: (typeof examples)[number]) {
    setTargetError(undefined);
    await setConsoleState({
      chainId: example.chainId,
      rpcUrl: example.rpcUrl,
      address: example.address,
      origins: example.externalOrigin,
      active: true,
    });
  }

  const loaded = interfaceQuery.data;
  return (
    <main>
      <header>
        <div>
          <p className="eyebrow">Experimental EVM interface</p>
          <h1>Application Interface Console</h1>
          <p>
            Discover semantic reads and prepare application actions from any
            compatible adapter.
          </p>
        </div>
        <WalletConnection />
      </header>

      <section className="about">
        <h2>About</h2>
        <p>
          This console is a reference client for experimental standards that let
          EVM applications expose semantic queries, prepare action bundles, and
          continue calls through client-mediated HTTP requests.
        </p>
        <nav aria-label="Project resources">
          <a
            href="https://github.com/stephancill/onchain-app-interfaces"
            target="_blank"
            rel="noreferrer"
          >
            GitHub repository
          </a>
          <a href={skillUrl} target="_blank" rel="noreferrer">
            Agent skill
          </a>
          <a
            href="https://github.com/stephancill/onchain-app-interfaces/blob/main/docs/eips/erc-draft-application-interfaces.md"
            target="_blank"
            rel="noreferrer"
          >
            Query and action draft
          </a>
          <a
            href="https://github.com/stephancill/onchain-app-interfaces/blob/main/docs/eips/erc-draft-external-request.md"
            target="_blank"
            rel="noreferrer"
          >
            External request draft
          </a>
        </nav>
      </section>

      <section className="examples">
        <h2>Examples</h2>
        <table>
          <thead>
            <tr>
              <th>Application</th>
              <th>Network</th>
              <th>Adapter</th>
              <th>External origin</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {examples.map((example) => (
              <tr key={example.address}>
                <td>{example.name}</td>
                <td>Base</td>
                <td>
                  <a
                    href={`https://basescan.org/address/${example.address}`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    <code>
                      {example.address.slice(0, 10)}...
                      {example.address.slice(-6)}
                    </code>
                  </a>
                </td>
                <td>{example.externalOrigin || "None"}</td>
                <td>
                  <button
                    type="button"
                    onClick={() => void loadExample(example)}
                  >
                    Load
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      <section className="panel">
        <h2>Load an adapter</h2>
        <form className="target-form" onSubmit={submitTarget}>
          <label>
            Chain ID
            <input
              inputMode="numeric"
              value={consoleState.chainId}
              onChange={(event) =>
                void setConsoleState({
                  chainId: event.target.value,
                  active: false,
                })
              }
            />
          </label>
          <label>
            RPC URL
            <input
              value={consoleState.rpcUrl}
              onChange={(event) =>
                void setConsoleState({
                  rpcUrl: event.target.value,
                  active: false,
                })
              }
              spellCheck={false}
            />
          </label>
          <label>
            Adapter address
            <input
              value={consoleState.address}
              onChange={(event) =>
                void setConsoleState({
                  address: event.target.value,
                  active: false,
                })
              }
              placeholder="0x..."
              spellCheck={false}
            />
          </label>
          <button type="submit" disabled={interfaceQuery.isFetching}>
            Load interface
          </button>
        </form>
        {(targetError || interfaceQuery.error) && (
          <p className="error">
            {targetError ?? errorMessage(interfaceQuery.error)}
          </p>
        )}
        {interfaceQuery.isFetching && (
          <p className="muted">
            Reading bytecode, capabilities, and descriptors...
          </p>
        )}
      </section>

      {loaded && (
        <>
          <section className="panel policy-panel">
            <div>
              <h2>External Request policy</h2>
              <p>
                Only needed for capabilities that continue through HTTP. Values
                stay in this page and are never sent onchain.
              </p>
            </div>
            <label>
              Allowed origins (one per line)
              <textarea
                value={consoleState.origins}
                onChange={(event) =>
                  void setConsoleState({ origins: event.target.value })
                }
                rows={3}
                placeholder="https://api.example.com"
                spellCheck={false}
              />
            </label>
            <label>
              Requirement values (JSON)
              <textarea
                value={requirementText}
                onChange={(event) => setRequirementText(event.target.value)}
                rows={3}
                placeholder={'{"HEADER:x-api-key":"..."}'}
                spellCheck={false}
              />
            </label>
            {policyError && <p className="error">{policyError}</p>}
            <p className="notice">
              This browser console enforces an exact origin allowlist, but
              cannot provide production-grade DNS rebinding and private-network
              checks. Browser CORS policy may also reject otherwise valid
              requests.
            </p>
          </section>

          <section className="summary">
            <div>
              <strong>{loaded.queries.length}</strong>
              <span>Queries</span>
            </div>
            <div>
              <strong>{loaded.actions.length}</strong>
              <span>Actions</span>
            </div>
            <div>
              <strong>{loaded.unsupported.length}</strong>
              <span>Optional interfaces absent</span>
            </div>
          </section>

          <section className="capabilities">
            {[...loaded.queries, ...loaded.actions].map((capability) => (
              <CapabilityCard
                key={`${capability.descriptor.kind}-${capability.id}`}
                capability={capability}
                target={target!}
                account={account}
                requirementValues={requirementValues}
                allowedOrigins={allowedOrigins}
              />
            ))}
          </section>
          {loaded.queries.length + loaded.actions.length === 0 && (
            <p className="empty">The adapter exposes no capabilities.</p>
          )}
        </>
      )}
    </main>
  );
}

export default App;

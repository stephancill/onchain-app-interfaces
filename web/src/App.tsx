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

const requirementValuesSchema = z.record(z.string(), z.string());
const baseRpcUrl = "https://evm.stupidtech.net/v1/8453";
const aerodromeWethUsdcPool = "0xcDAC0d6c6C59727a65F871236188350531885C43";
const examples = [
  {
    name: "Aerodrome",
    chainId: "8453",
    rpcUrl: baseRpcUrl,
    address: "0x9c952d2530e8e94512f14fe6987fccb5d8a3b6e2",
    externalOrigin: "",
  },
  {
    name: "Moonwell",
    chainId: "8453",
    rpcUrl: baseRpcUrl,
    address: "0xf5c03ce6356d9dafe49f3254b38f7e747958b0c0",
    externalOrigin: "https://api.moonwell.fi",
  },
  {
    name: "Avantis",
    chainId: "8453",
    rpcUrl: baseRpcUrl,
    address: "0xfa5725214419f9688133841f67e10c4783d17b26",
    externalOrigin:
      "https://core.avantisfi.com\nhttps://tx-builder.avantisfi.com",
  },
  {
    name: "Relay",
    chainId: "8453",
    rpcUrl: baseRpcUrl,
    address: "0x2BE7659C8e7627F1C2aB08CebA6bcb72D50747E5",
    externalOrigin: "https://api.relay.link",
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

function emptyFieldValue(field: DescriptorField, account?: Address): unknown {
  const core = field.abiType.split("[]")[0] ?? field.abiType;
  if (core === "tuple") {
    return Object.fromEntries(
      (field.components ?? []).map((component) => [
        component.name,
        emptyFieldValue(component, account),
      ]),
    );
  }
  if (field.abiType === "address") return account ?? "";
  if (field.abiType === "bool") return false;
  if (field.semanticType === "timestamp") {
    return String(Math.floor(Date.now() / 1000) + 60 * 60);
  }
  if (field.enumValues !== undefined) {
    return Object.keys(field.enumValues)[0] ?? "";
  }
  if (/^u?int/.test(field.abiType)) return field.minimum ?? "0";
  if (field.abiType.startsWith("bytes")) return "0x";
  return "";
}

const nativeZero = "0x0000000000000000000000000000000000000000";
function initialEditorValue(
  descriptor: ApplicationDescriptor,
  account?: Address,
): Record<string, unknown> {
  const bound = account ?? "0x0000000000000000000000000000000000000000";
  if (descriptor.name === "aerodrome.poolState") {
    return { pool: aerodromeWethUsdcPool };
  }
  if (descriptor.name === "aerodrome.lpPosition") {
    return { pool: aerodromeWethUsdcPool, account: bound };
  }
  if (descriptor.name === "aerodrome.swapQuote.exactInput") {
    return {
      pool: aerodromeWethUsdcPool,
      tokenIn: "0x4200000000000000000000000000000000000006",
      tokenOut: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      amountIn: "1000000000000000000",
    };
  }
  if (descriptor.name === "aerodrome.swap.exactInput") {
    return {
      parameters: {
        pool: aerodromeWethUsdcPool,
        tokenIn: "0x4200000000000000000000000000000000000006",
        tokenOut: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        amountIn: "1000000000000000000",
        maxSlippageBps: "100",
        deadline: String(Math.floor(Date.now() / 1000) + 60 * 60),
      },
    };
  }
  if (
    descriptor.name === "moonwell.position.usdc" ||
    descriptor.name === "moonwell.positions" ||
    descriptor.name === "moonwell.health" ||
    descriptor.name === "avantis.positions" ||
    descriptor.name === "avantis.account"
  ) {
    return { account: bound };
  }
  if (descriptor.name === "moonwell.supply.usdc") {
    return {
      parameters: { amount: "1000000", enableAsCollateral: false },
    };
  }
  if (descriptor.name === "avantis.markets") return {};
  if (descriptor.name === "avantis.market") return { pairIndex: "0" };
  if (descriptor.name === "avantis.trade.open") {
    return {
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
    };
  }
  if (descriptor.name === "avantis.trade.close") {
    return {
      parameters: {
        pairIndex: "0",
        tradeIndex: "0",
        collateralToCloseUsdc: "50000000",
        expectedPrice: "40000000000000",
        executionFeeWei: "350000000000000",
      },
    };
  }
  if (descriptor.name === "avantis.limit.cancel") {
    return { parameters: { pairIndex: "0", orderIndex: "0" } };
  }
  if (descriptor.name === "avantis.limit.update") {
    return {
      parameters: {
        pairIndex: "0",
        orderIndex: "0",
        price: "40000000000000",
        slippagePercent: "10000000000",
        takeProfit: "50000000000000",
        stopLoss: "30000000000000",
      },
    };
  }
  if (descriptor.name === "avantis.position.increase") {
    return {
      parameters: {
        pairIndex: "0",
        tradeIndex: "0",
        additionalCollateralUsdc: "25000000",
        leverage: "100000000000",
        openPrice: "40000000000000",
        slippagePercent: "10000000000",
      },
    };
  }
  if (descriptor.name === "avantis.margin.update") {
    return {
      parameters: {
        pairIndex: "0",
        tradeIndex: "0",
        action: "DEPOSIT",
        collateralUsdc: "25000000",
        priceSourcing: "PRO",
        oracleFeeWei: "1",
      },
    };
  }
  if (descriptor.name === "relay.route.quote") {
    return {
      account: bound,
      originChainId: "8453",
      destinationChainId: "10",
      originCurrency: nativeZero,
      destinationCurrency: nativeZero,
      amount: "1000000000000000",
    };
  }
  if (descriptor.name === "relay.bridge.exactInput") {
    return {
      parameters: {
        originChainId: "8453",
        destinationChainId: "10",
        originCurrency: nativeZero,
        destinationCurrency: nativeZero,
        amount: "1000000000000000",
        recipient: "0x",
        slippageBps: "30",
        ttlSeconds: "600",
      },
    };
  }
  return Object.fromEntries(
    descriptor.inputs.fields.map((field) => [
      field.name,
      emptyFieldValue(field, account),
    ]),
  );
}

function fieldValidation(
  field: DescriptorField,
  value: unknown,
): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  if (field.abiType === "address") {
    return typeof value === "string" && isAddress(value)
      ? undefined
      : "Enter a valid 0x address";
  }
  if (/^u?int/.test(field.abiType)) {
    const text = String(value);
    const valid = /^(0|[1-9][0-9]*)$/.test(text);
    if (!valid) return "Enter a non-negative decimal integer";
    const parsed = BigInt(text);
    if (field.minimum !== undefined && parsed < BigInt(field.minimum)) {
      return `At least ${field.minimum}`;
    }
    if (field.maximum !== undefined && parsed > BigInt(field.maximum)) {
      return `At most ${field.maximum}`;
    }
    return undefined;
  }
  if (field.abiType.startsWith("bytes")) {
    const text = String(value);
    if (!/^0x[0-9a-fA-F]*$/.test(text)) return "Enter 0x hex";
    if (field.abiType === "bytes32" && text.length !== 66) {
      return "bytes32 must be exactly 64 hex digits";
    }
    return undefined;
  }
  if (field.abiType === "string") {
    const text = String(value);
    if (field.minLength !== undefined && text.length < field.minLength) {
      return `At least ${field.minLength} characters`;
    }
    if (field.maxLength !== undefined && text.length > field.maxLength) {
      return `At most ${field.maxLength} characters`;
    }
  }
  return undefined;
}

function fieldHint(field: DescriptorField): string {
  const parts: string[] = [];
  if (field.semanticType !== undefined) parts.push(field.semanticType);
  if (field.minimum !== undefined) parts.push(`min ${field.minimum}`);
  if (field.maximum !== undefined) parts.push(`max ${field.maximum}`);
  return parts.join(" \u00b7 ");
}

function EditorField(parameters: {
  field: DescriptorField;
  value: unknown;
  account?: Address;
  onChange: (value: unknown) => void;
}) {
  const { field, value, account, onChange } = parameters;
  const core = field.abiType.split("[]")[0] ?? field.abiType;

  if (core === "tuple") {
    const record = (value ?? {}) as Record<string, unknown>;
    return (
      <fieldset className="rounded border border-current px-2.5 pt-2 pb-2.5">
        <legend className="px-1 font-semibold">{field.name}</legend>
        <EditorFields
          fields={field.components ?? []}
          values={record}
          account={account}
          onChange={(next) => onChange(next)}
        />
      </fieldset>
    );
  }

  if (field.abiType === "bool") {
    return (
      <label className="flex items-center gap-2">
        <input
          type="checkbox"
          checked={value === true}
          onChange={(event) => onChange(event.target.checked)}
        />
        <span>{field.name}</span>
      </label>
    );
  }

  if (field.enumValues !== undefined) {
    const labels = Object.keys(field.enumValues);
    const current =
      typeof value === "string" && labels.includes(value) ? value : "";
    return (
      <label className="grid gap-1">
        <span>
          {field.name}
          {fieldHint(field) && (
            <em className="text-[0.85em] not-italic opacity-60">
              {" "}
              {fieldHint(field)}
            </em>
          )}
        </span>
        <select
          value={current}
          onChange={(event) => onChange(event.target.value)}
        >
          {labels.map((label) => (
            <option key={label} value={label}>
              {label}
            </option>
          ))}
        </select>
      </label>
    );
  }

  const validation = fieldValidation(field, value);
  return (
    <label className="grid gap-1">
      <span>
        {field.name}
        {fieldHint(field) && (
          <em className="text-[0.85em] not-italic opacity-60">
            {" "}
            {fieldHint(field)}
          </em>
        )}
      </span>
      <input
        type="text"
        value={value === undefined || value === null ? "" : String(value)}
        onChange={(event) => onChange(event.target.value)}
        placeholder={
          field.abiType === "address"
            ? "0x..."
            : field.abiType.startsWith("bytes")
              ? "0x..."
              : undefined
        }
        spellCheck={false}
        aria-invalid={validation !== undefined || undefined}
      />
      {validation !== undefined && (
        <small className="text-[0.8em] text-red-600">{validation}</small>
      )}
    </label>
  );
}

function EditorFields(parameters: {
  fields: readonly DescriptorField[];
  values: Record<string, unknown>;
  account?: Address;
  onChange: (next: Record<string, unknown>) => void;
}) {
  const { fields, values, account, onChange } = parameters;
  return (
    <div className="my-2 grid gap-2">
      {fields.map((field) => (
        <EditorField
          key={field.name}
          field={field}
          value={values[field.name]}
          account={account}
          onChange={(value) => onChange({ ...values, [field.name]: value })}
        />
      ))}
    </div>
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
  const [editorValues, setEditorValues] = useState(() =>
    initialEditorValue(capability.descriptor, account),
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
      const encodedParameters = encodeDescriptorParameters({
        descriptor: capability.descriptor,
        values: editorValues,
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
    <details className="group grid min-w-0 content-start self-start gap-3 border border-current p-4 [&>*]:min-w-0">
      <summary className="grid cursor-pointer list-none select-none gap-2 [&::-webkit-details-marker]:hidden md:flex md:items-center md:justify-between md:gap-2.5">
        <span className="flex min-w-0 items-center gap-2.5">
          <span className="shrink-0 rounded-full border border-current px-2 py-0.5 text-[0.7em] tracking-[0.08em] uppercase">
            {descriptor.kind}
          </span>
          <span className="min-w-0 flex-1 font-semibold">
            {descriptor.name}
          </span>
          <span
            className="shrink-0 opacity-70 transition-transform duration-150 group-open:rotate-90 md:hidden"
            aria-hidden="true"
          >
            ▸
          </span>
        </span>
        <span className="flex items-center gap-2.5">
          {mutation.isPending && (
            <span
              className="h-2 w-2 shrink-0 rounded-full bg-amber-600"
              title="Resolving"
            />
          )}
          {mutation.error && (
            <span
              className="h-2 w-2 shrink-0 rounded-full bg-red-600"
              title="Failed"
            />
          )}
          {mutation.data && (
            <span
              className="h-2 w-2 shrink-0 rounded-full bg-green-600"
              title="Completed"
            />
          )}
          <code className="truncate md:whitespace-nowrap" title={capability.id}>
            {capability.id.slice(0, 10)}...{capability.id.slice(-6)}
          </code>
          <span
            className="hidden shrink-0 opacity-70 transition-transform duration-150 group-open:rotate-90 md:inline"
            aria-hidden="true"
          >
            ▸
          </span>
        </span>
      </summary>
      {descriptor.description && <p>{descriptor.description}</p>}
      <dl className="flex flex-wrap gap-4 max-md:flex-col">
        <div className="grid gap-1 border border-current p-2">
          <dt>Provenance</dt>
          <dd>{descriptor.provenance?.type ?? "not declared"}</dd>
        </div>
        <div className="grid gap-1 border border-current p-2">
          <dt>Inputs</dt>
          <dd>{descriptor.inputs.fields.length}</dd>
        </div>
        {descriptor.kind === "action" && (
          <div className="grid gap-1 border border-current p-2">
            <dt>Atomicity</dt>
            <dd>{descriptor.execution?.atomicity ?? "not declared"}</dd>
          </div>
        )}
      </dl>
      <details>
        <summary className="cursor-pointer select-none">Descriptor</summary>
        <pre className="max-h-80 overflow-auto">{jsonValue(descriptor)}</pre>
      </details>
      {descriptor.kind === "action" && (
        <label className="grid gap-3">
          Preparation account
          <input
            value={actionAccount}
            onChange={(event) => setActionAccount(event.target.value)}
            placeholder="0x..."
            spellCheck={false}
          />
        </label>
      )}
      <div>
        <strong>Input values</strong>
        <EditorFields
          fields={descriptor.inputs.fields}
          values={editorValues}
          account={account}
          onChange={setEditorValues}
        />
      </div>
      <details>
        <summary className="cursor-pointer select-none">
          Encoded values (JSON)
        </summary>
        <pre className="max-h-60 overflow-auto text-[0.85em] opacity-90">
          {jsonValue(editorValues)}
        </pre>
      </details>
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
        <p className="text-red-600">{errorMessage(mutation.error)}</p>
      )}
      {mutation.data && (
        <div className="grid min-w-0 gap-2">
          <strong>
            {descriptor.kind === "query"
              ? "Semantic result"
              : "Prepared calls (not executed)"}
          </strong>
          <pre className="max-h-[360px] overflow-auto">
            {jsonValue(mutation.data)}
          </pre>
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
                <p className="text-red-600">
                  {executionError ??
                    errorMessage(sendCalls.error ?? callsStatus.error)}
                </p>
              )}
              {sendCalls.data && (
                <div className="grid gap-1">
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
    </details>
  );
}

function WalletConnection() {
  const connection = useConnection();
  const connectors = useConnectors();
  const { connect, error } = useConnect();
  const { disconnect } = useDisconnect();

  if (connection.status === "connected") {
    return (
      <div className="flex flex-wrap items-center gap-4">
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
    <div className="flex flex-wrap items-center gap-4">
      {connectors.map((connector) => (
        <button
          key={connector.uid}
          type="button"
          onClick={() => connect({ connector })}
        >
          Connect {connector.name}
        </button>
      ))}
      {error && <span className="text-red-600">{error.message}</span>}
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
  const columnClass = (full: boolean) =>
    `grid min-w-0 content-start gap-3 ${
      full ? "col-span-2 max-md:col-span-1" : ""
    }`;
  return (
    <main className="grid w-full gap-4 px-4 pb-[max(64px,env(safe-area-inset-bottom))] pt-6 sm:px-6 lg:px-8">
      <header className="flex flex-wrap items-start justify-between gap-4 max-md:flex-col">
        <div className="grid gap-2">
          <p className="text-[0.8em] tracking-[0.08em] uppercase opacity-60">
            Experimental EVM interface
          </p>
          <h1 className="text-3xl font-bold">Application Interface Console</h1>
          <p>
            Discover semantic reads and prepare application actions from any
            compatible adapter.
          </p>
        </div>
        <WalletConnection />
      </header>

      <section className="grid gap-2 border-y py-4">
        <h2 className="text-2xl font-bold">About</h2>
        <p>
          This console is a reference client for experimental standards that let
          EVM applications expose semantic queries, prepare action bundles, and
          continue calls through client-mediated HTTP requests.
        </p>
        <nav className="flex flex-wrap gap-4" aria-label="Project resources">
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

      <section className="grid gap-2 overflow-x-auto">
        <h2 className="text-2xl font-bold">Examples</h2>
        <table className="w-full border-collapse">
          <thead>
            <tr>
              <th className="border border-current px-2 py-2 text-left">
                Application
              </th>
              <th className="border border-current px-2 py-2 text-left">
                Network
              </th>
              <th className="border border-current px-2 py-2 text-left">
                Adapter
              </th>
              <th className="border border-current px-2 py-2 text-left">
                External origin
              </th>
              <th className="border border-current px-2 py-2 text-left"></th>
            </tr>
          </thead>
          <tbody>
            {examples.map((example) => (
              <tr key={example.address}>
                <td className="border border-current px-2 py-2 text-left">
                  {example.name}
                </td>
                <td className="border border-current px-2 py-2 text-left">
                  Base
                </td>
                <td className="border border-current px-2 py-2 text-left">
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
                <td className="border border-current px-2 py-2 text-left">
                  {example.externalOrigin || "None"}
                </td>
                <td className="border border-current px-2 py-2 text-left">
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

      <section className="grid gap-3">
        <h2 className="text-2xl font-bold">Load an adapter</h2>
        <form
          className="grid grid-cols-[100px_1fr_1.3fr_auto] items-end gap-3 max-md:grid-cols-1"
          onSubmit={submitTarget}
        >
          <label className="grid gap-3">
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
          <label className="grid gap-3">
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
          <label className="grid gap-3">
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
          <p className="text-red-600">
            {targetError ?? errorMessage(interfaceQuery.error)}
          </p>
        )}
        {interfaceQuery.isFetching && (
          <p className="text-sm opacity-60">
            Reading bytecode, capabilities, and descriptors...
          </p>
        )}
      </section>

      {loaded && (
        <>
          <section className="grid grid-cols-2 gap-3 max-md:grid-cols-1">
            <div className="col-span-2 grid gap-2 max-md:col-span-1">
              <h2 className="text-2xl font-bold">External Request policy</h2>
              <p>
                Only needed for capabilities that continue through HTTP. Values
                stay in this page and are never sent onchain.
              </p>
            </div>
            <label className="grid gap-3">
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
            <label className="grid gap-3">
              Requirement values (JSON)
              <textarea
                value={requirementText}
                onChange={(event) => setRequirementText(event.target.value)}
                rows={3}
                placeholder={'{"HEADER:x-api-key":"..."}'}
                spellCheck={false}
              />
            </label>
            {policyError && (
              <p className="col-span-2 text-red-600 max-md:col-span-1">
                {policyError}
              </p>
            )}
            <p className="col-span-2 max-md:col-span-1">
              This browser console enforces an exact origin allowlist, but
              cannot provide production-grade DNS rebinding and private-network
              checks. Browser CORS policy may also reject otherwise valid
              requests.
            </p>
          </section>

          <section className="grid gap-4 md:flex md:gap-4">
            <div className="grid gap-1 border border-current p-2 md:flex-1">
              <strong>{loaded.queries.length}</strong>
              <span>Queries</span>
            </div>
            <div className="grid gap-1 border border-current p-2 md:flex-1">
              <strong>{loaded.actions.length}</strong>
              <span>Actions</span>
            </div>
            <div className="grid gap-1 border border-current p-2 md:flex-1">
              <strong>{loaded.unsupported.length}</strong>
              <span>Optional interfaces absent</span>
            </div>
          </section>

          <section className="grid grid-cols-2 items-start gap-3 max-md:grid-cols-1">
            {loaded.queries.length > 0 && (
              <div className={columnClass(loaded.actions.length === 0)}>
                <h2 className="text-2xl font-bold">Queries</h2>
                {loaded.queries.map((capability) => (
                  <CapabilityCard
                    key={`query-${capability.id}`}
                    capability={capability}
                    target={target!}
                    account={account}
                    requirementValues={requirementValues}
                    allowedOrigins={allowedOrigins}
                  />
                ))}
              </div>
            )}
            {loaded.actions.length > 0 && (
              <div className={columnClass(loaded.queries.length === 0)}>
                <h2 className="text-2xl font-bold">Actions</h2>
                {loaded.actions.map((capability) => (
                  <CapabilityCard
                    key={`action-${capability.id}`}
                    capability={capability}
                    target={target!}
                    account={account}
                    requirementValues={requirementValues}
                    allowedOrigins={allowedOrigins}
                  />
                ))}
              </div>
            )}
          </section>
          {loaded.queries.length + loaded.actions.length === 0 && (
            <p>The adapter exposes no capabilities.</p>
          )}
        </>
      )}
    </main>
  );
}

export default App;

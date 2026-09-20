import {
  decodeFunctionResult,
  encodeFunctionData,
  hexToBytes,
  type Address,
} from "viem";
import { z } from "zod";

import { executeHttpRequest, validateRequest } from "./request.ts";
import type {
  AuthorizeRequest,
  EthCall,
  HttpFetch,
  HttpRequest,
} from "./types.ts";

export const maxMetadataBytes = 65_536;
export const maxMetadataUriBytes = 3 * maxMetadataBytes + 256;

export const contractMetadataAbi = [
  {
    type: "function",
    name: "contractURI",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "uri", type: "string" }],
  },
  { type: "event", name: "ContractURIUpdated", inputs: [] },
] as const;

const nonemptyText = z.string().refine((value) => value.trim().length > 0);
const uriSchema = z.string().regex(/^[a-zA-Z][a-zA-Z0-9+.-]*:\S+$/);

export const contractMetadataSchema = z.looseObject({
  name: nonemptyText,
  description: nonemptyText,
  symbol: z.string().optional(),
  image: uriSchema.optional(),
  banner_image: uriSchema.optional(),
  featured_image: uriSchema.optional(),
  external_link: uriSchema.optional(),
  collaborators: z.array(z.string()).optional(),
});

export type ContractMetadata = z.infer<typeof contractMetadataSchema>;
export type ResolvedContractMetadata = {
  uri: string;
  metadata: ContractMetadata;
};
export type MetadataResolutionOptions = {
  authorizeRequest?: AuthorizeRequest;
  fetch?: HttpFetch;
  /** HTTPS gateway origin, e.g. https://ipfs.io. Its origin must be authorized. */
  ipfsGateway?: string;
};

function boundedBytes(parameters: {
  value: string;
  limit: number;
}): Uint8Array {
  if (parameters.value.length > parameters.limit)
    throw new Error("Metadata exceeds client size limit");
  const bytes = new TextEncoder().encode(parameters.value);
  if (bytes.length > parameters.limit)
    throw new Error("Metadata exceeds client size limit");
  return bytes;
}

export function parseContractMetadata(parameters: {
  json: string;
}): ContractMetadata {
  try {
    boundedBytes({ value: parameters.json, limit: maxMetadataBytes });
    return contractMetadataSchema.parse(JSON.parse(parameters.json));
  } catch (cause) {
    throw new Error(
      "Invalid application metadata: expected ERC-7572 JSON with nonempty name and description",
      { cause },
    );
  }
}

function decodeJsonBytes(parameters: { bytes: Uint8Array }): ContractMetadata {
  try {
    if (parameters.bytes.length > maxMetadataBytes)
      throw new Error("Metadata exceeds client size limit");
    const json = new TextDecoder("utf-8", {
      fatal: true,
      ignoreBOM: true,
    }).decode(parameters.bytes);
    return parseContractMetadata({ json });
  } catch (cause) {
    throw new Error("Invalid application metadata document", { cause });
  }
}

function decodeDataUri(parameters: { uri: string }): ContractMetadata {
  try {
    const match =
      /^data:application\/json(?:(;utf8|;charset=utf-8))?(;base64)?,([\s\S]*)$/i.exec(
        parameters.uri,
      );
    if (!match) throw new Error("Unsupported JSON data URI encoding");
    const payload = decodeURIComponent(match[3]!);
    if (!match[2]) return parseContractMetadata({ json: payload });
    if (
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(
        payload,
      )
    )
      throw new Error("Invalid Base64");
    const binary = atob(payload);
    if (btoa(binary) !== payload) throw new Error("Noncanonical Base64");
    return decodeJsonBytes({
      bytes: Uint8Array.from(binary, (character) => character.charCodeAt(0)),
    });
  } catch (cause) {
    throw new Error("Invalid application metadata data URI", { cause });
  }
}

function remoteUrl(parameters: { uri: string; ipfsGateway?: string }): string {
  if (parameters.uri.startsWith("https://")) return parameters.uri;
  if (!parameters.uri.startsWith("ipfs://"))
    throw new Error("Metadata resolution failed: unsupported URI scheme");
  if (!parameters.ipfsGateway)
    throw new Error(
      "Metadata resolution failed: IPFS requires a configured HTTPS gateway",
    );
  const gateway = new URL(parameters.ipfsGateway);
  if (
    gateway.protocol !== "https:" ||
    gateway.username ||
    gateway.password ||
    gateway.search ||
    gateway.hash ||
    gateway.pathname !== "/"
  )
    throw new Error(
      "Metadata resolution failed: IPFS gateway must be an HTTPS origin",
    );
  const match = /^ipfs:\/\/([a-zA-Z0-9]+)((?:\/[^?#]*)?)$/.exec(parameters.uri);
  if (!match) throw new Error("Metadata resolution failed: invalid IPFS URI");
  const segments = match[2]!
    .split("/")
    .slice(1)
    .map((segment) => {
      const decoded = decodeURIComponent(segment);
      if (decoded === "." || decoded === ".." || /[\\/]/.test(decoded))
        throw new Error("Metadata resolution failed: invalid IPFS path");
      return encodeURIComponent(decoded);
    });
  return `${gateway.origin}/ipfs/${match[1]}${segments.length ? `/${segments.join("/")}` : ""}`;
}

export async function resolveContractMetadata(
  parameters: MetadataResolutionOptions & { uri: string },
): Promise<ResolvedContractMetadata> {
  boundedBytes({ value: parameters.uri, limit: maxMetadataUriBytes });
  if (!parameters.uri)
    throw new Error("Invalid application metadata: contractURI() is empty");
  if (/^data:/i.test(parameters.uri))
    return {
      uri: parameters.uri,
      metadata: decodeDataUri({ uri: parameters.uri }),
    };

  let body: Uint8Array;
  try {
    const url = remoteUrl(parameters);
    const request: HttpRequest = {
      url,
      method: "GET",
      headers: [{ name: "Accept", value: "application/json" }],
      body: "0x",
      requirements: [],
    };
    validateRequest(request);
    if (!parameters.authorizeRequest)
      throw new Error("Remote metadata requires network authorization");
    await parameters.authorizeRequest({
      request,
      completedRequest: request,
      requirements: [],
    });
    const response = await executeHttpRequest({
      request,
      maxResponseBytes: maxMetadataBytes,
      fetch: (input, init) =>
        (parameters.fetch ?? globalThis.fetch)(input, {
          ...init,
          credentials: "omit",
          signal: AbortSignal.timeout(30_000),
        }),
    });
    if (response.status < 200 || response.status >= 300)
      throw new Error(`Metadata HTTP status ${response.status}`);
    body = hexToBytes(response.body);
  } catch (cause) {
    throw new Error(
      `Metadata resolution failed: ${cause instanceof Error ? cause.message : String(cause)}`,
      { cause },
    );
  }
  return { uri: parameters.uri, metadata: decodeJsonBytes({ bytes: body }) };
}

export async function readContractMetadata(
  parameters: MetadataResolutionOptions & {
    address: Address;
    ethCall: EthCall;
  },
): Promise<ResolvedContractMetadata> {
  let result;
  try {
    result = await parameters.ethCall({
      to: parameters.address,
      data: encodeFunctionData({
        abi: contractMetadataAbi,
        functionName: "contractURI",
      }),
    });
  } catch (cause) {
    throw new Error(
      "Required contractURI() call failed; application metadata could not be read",
      { cause },
    );
  }
  let uri: string;
  try {
    uri = decodeFunctionResult({
      abi: contractMetadataAbi,
      functionName: "contractURI",
      data: result,
    });
  } catch (cause) {
    throw new Error(
      "Invalid contractURI() return: required application metadata is missing or malformed",
      { cause },
    );
  }
  return resolveContractMetadata({ ...parameters, uri });
}

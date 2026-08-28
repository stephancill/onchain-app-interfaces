import { bytesToHex, hexToBytes, keccak256 } from "viem";

import type {
  CompletedHttpRequest,
  HttpFetch,
  HttpRequest,
  HttpResponse,
  RequestRequirement,
  ResolvedRequirement,
  ResolveRequirement,
} from "./types.ts";

const headerNamePattern = /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/;
const methodPattern = /^[A-Z]+$/;

function normalizedRequirementPath(requirement: RequestRequirement): string {
  return requirement.location === "HEADER"
    ? requirement.path.toLowerCase()
    : requirement.path;
}

function contentType(
  headers: readonly { name: string; value: string }[],
): string | undefined {
  return headers
    .find((header) => header.name.toLowerCase() === "content-type")
    ?.value.split(";", 1)[0]
    ?.trim()
    .toLowerCase();
}

export function validateRequest(request: HttpRequest): void {
  const url = new URL(request.url);
  if (url.protocol !== "https:")
    throw new Error("External request URL must use HTTPS");
  if (url.username || url.password)
    throw new Error("External request URL must not contain user info");
  if (url.hash)
    throw new Error("External request URL must not contain a fragment");
  if (!methodPattern.test(request.method))
    throw new Error("External request method must be uppercase ASCII");

  const headerNames = new Set<string>();
  for (const header of request.headers) {
    if (!headerNamePattern.test(header.name))
      throw new Error(`Invalid HTTP header name: ${header.name}`);
    if (/\r|\n/.test(header.value))
      throw new Error(`Invalid HTTP header value for ${header.name}`);
    const name = header.name.toLowerCase();
    if (headerNames.has(name))
      throw new Error(`Duplicate HTTP header: ${header.name}`);
    headerNames.add(name);
  }

  const requirementKeys = new Set<string>();
  for (const requirement of request.requirements) {
    if (
      requirement.location === "HEADER" &&
      !headerNamePattern.test(requirement.path)
    ) {
      throw new Error(`Invalid required HTTP header name: ${requirement.path}`);
    }
    const key = `${requirement.location}:${normalizedRequirementPath(requirement)}`;
    if (requirementKeys.has(key))
      throw new Error(`Duplicate request requirement: ${key}`);
    requirementKeys.add(key);
    if (
      requirement.location === "HEADER" &&
      headerNames.has(requirement.path.toLowerCase())
    ) {
      throw new Error(
        `Required HTTP header is already present: ${requirement.path}`,
      );
    }
  }
}

function decodeJsonPointer(pointer: string): string[] {
  if (pointer === "") return [];
  if (!pointer.startsWith("/"))
    throw new Error(`Invalid JSON Pointer: ${pointer}`);

  return pointer
    .slice(1)
    .split("/")
    .map((token) => {
      if (/~(?:[^01]|$)/.test(token))
        throw new Error(`Invalid JSON Pointer escape: ${pointer}`);
      return token.replaceAll("~1", "/").replaceAll("~0", "~");
    });
}

function insertJsonValue(
  document: unknown,
  pointer: string,
  value: string,
): unknown {
  const tokens = decodeJsonPointer(pointer);
  if (tokens.length === 0) return value;

  let parent = document;
  for (const token of tokens.slice(0, -1)) {
    if (
      typeof parent !== "object" ||
      parent === null ||
      Array.isArray(parent)
    ) {
      throw new Error(`JSON Pointer parent is not an object: ${pointer}`);
    }
    if (!Object.hasOwn(parent, token))
      throw new Error(`JSON Pointer parent does not exist: ${pointer}`);
    parent = (parent as Record<string, unknown>)[token];
  }

  if (typeof parent !== "object" || parent === null || Array.isArray(parent)) {
    throw new Error(`JSON Pointer parent is not an object: ${pointer}`);
  }

  const finalToken = tokens.at(-1);
  if (finalToken === undefined || finalToken === "-")
    throw new Error(`Unsupported JSON Pointer: ${pointer}`);
  (parent as Record<string, unknown>)[finalToken] = value;
  return document;
}

export async function completeRequest(parameters: {
  request: HttpRequest;
  resolveRequirement: ResolveRequirement;
}): Promise<{
  request: CompletedHttpRequest;
  requirements: ResolvedRequirement[];
}> {
  validateRequest(parameters.request);

  const resolvedRequirements: ResolvedRequirement[] = [];
  for (const requirement of parameters.request.requirements) {
    const value = await parameters.resolveRequirement({
      requirement,
      request: parameters.request,
    });
    if (/\r|\n/.test(value) && requirement.location === "HEADER") {
      throw new Error(
        `Invalid required HTTP header value for ${requirement.path}`,
      );
    }
    resolvedRequirements.push({ requirement, value });
  }

  const url = new URL(parameters.request.url);
  const headers = parameters.request.headers.map((header) => ({ ...header }));
  let body = hexToBytes(parameters.request.body);
  let jsonDocument: unknown;
  let form: URLSearchParams | undefined;
  const mediaType = contentType(headers);

  for (const resolved of resolvedRequirements) {
    const { requirement, value } = resolved;
    if (requirement.location === "HEADER") {
      headers.push({ name: requirement.path, value });
      continue;
    }

    if (requirement.location === "QUERY") {
      if (url.searchParams.has(requirement.path)) {
        throw new Error(
          `Required query parameter is already present: ${requirement.path}`,
        );
      }
      url.searchParams.append(requirement.path, value);
      continue;
    }

    if (mediaType === "application/json") {
      jsonDocument ??= JSON.parse(new TextDecoder().decode(body));
      jsonDocument = insertJsonValue(jsonDocument, requirement.path, value);
      continue;
    }

    if (mediaType === "application/x-www-form-urlencoded") {
      form ??= new URLSearchParams(new TextDecoder().decode(body));
      if (form.has(requirement.path)) {
        throw new Error(
          `Required form field is already present: ${requirement.path}`,
        );
      }
      form.append(requirement.path, value);
      continue;
    }

    throw new Error(
      `Unsupported Content-Type for body requirement: ${mediaType ?? "none"}`,
    );
  }

  if (jsonDocument !== undefined)
    body = new TextEncoder().encode(JSON.stringify(jsonDocument));
  if (form !== undefined) body = new TextEncoder().encode(form.toString());

  return {
    request: {
      url: url.toString(),
      method: parameters.request.method,
      headers,
      body: bytesToHex(body),
    },
    requirements: resolvedRequirements,
  };
}

export async function executeHttpRequest(parameters: {
  request: CompletedHttpRequest;
  fetch?: HttpFetch;
  maxResponseBytes?: number;
}): Promise<HttpResponse> {
  const fetchImplementation = parameters.fetch ?? globalThis.fetch;
  const requestInit: RequestInit = {
    method: parameters.request.method,
    headers: parameters.request.headers.map((header): [string, string] => [
      header.name,
      header.value,
    ]),
    redirect: "manual",
  };
  if (parameters.request.body !== "0x") {
    requestInit.body = Uint8Array.from(hexToBytes(parameters.request.body));
  }
  const response = await fetchImplementation(
    parameters.request.url,
    requestInit,
  );
  const body = new Uint8Array(await response.arrayBuffer());
  const maxResponseBytes = parameters.maxResponseBytes ?? 1_048_576;
  if (body.byteLength > maxResponseBytes) {
    throw new Error(`HTTP response exceeds ${maxResponseBytes} bytes`);
  }

  const bodyHex = bytesToHex(body);
  return {
    status: response.status,
    headers: [...response.headers.entries()].map(([name, value]) => ({
      name,
      value,
    })),
    rawBodyHash: keccak256(bodyHex),
    bodyEncoding: "RAW",
    body: bodyHex,
  };
}

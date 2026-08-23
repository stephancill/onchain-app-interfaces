import type { Address, Hex } from "viem";

export const requestLocations = ["HEADER", "QUERY", "BODY"] as const;

export type RequestLocation = (typeof requestLocations)[number];

export type HttpHeader = {
  name: string;
  value: string;
};

export type RequestRequirement = {
  location: RequestLocation;
  path: string;
  description: string;
  sensitive: boolean;
};

export type HttpRequest = {
  url: string;
  method: string;
  headers: HttpHeader[];
  body: Hex;
  requirements: RequestRequirement[];
};

export type CompletedHttpRequest = Omit<HttpRequest, "requirements">;

export type HttpResponse = {
  status: number;
  headers: HttpHeader[];
  body: Hex;
};

export type ExternalRequestData = {
  sender: Address;
  request: HttpRequest;
  callbackFunction: Hex;
  extraData: Hex;
};

export type EvmCall = {
  to: Address;
  data: Hex;
};

export type ResolvedRequirement = {
  requirement: RequestRequirement;
  value: string;
};

export type ResolveRequirement = (parameters: {
  requirement: RequestRequirement;
  request: HttpRequest;
}) => Promise<string> | string;

export type AuthorizeRequest = (parameters: {
  request: HttpRequest;
  completedRequest: CompletedHttpRequest;
  requirements: readonly ResolvedRequirement[];
}) => Promise<void> | void;

export type EthCall = (call: EvmCall) => Promise<Hex>;

export type HttpFetch = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

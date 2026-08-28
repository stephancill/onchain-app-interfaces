import { isHex, type Hex } from "viem";

import {
  assertSenderMatches,
  decodeExternalRequest,
  encodeExternalRequestCallback,
} from "./abi.ts";
import { completeRequest, executeHttpRequest } from "./request.ts";
import { transformHttpResponse } from "./transform.ts";
import type {
  AuthorizeRequest,
  EthCall,
  EvmCall,
  HttpFetch,
  ResolveRequirement,
} from "./types.ts";

function extractRevertData(
  error: unknown,
  seen = new Set<unknown>(),
): Hex | undefined {
  if (typeof error === "string" && isHex(error)) return error;
  if (typeof error !== "object" || error === null || seen.has(error))
    return undefined;
  seen.add(error);

  const record = error as Record<string, unknown>;
  if (typeof record.data === "string" && isHex(record.data)) return record.data;

  for (const key of ["cause", "error", "details"] as const) {
    const nested = extractRevertData(record[key], seen);
    if (nested !== undefined) return nested;
  }
  return undefined;
}

export async function resolveCall(parameters: {
  call: EvmCall;
  ethCall: EthCall;
  resolveRequirement: ResolveRequirement;
  authorizeRequest: AuthorizeRequest;
  fetch?: HttpFetch;
  maxRequests?: number;
  maxResponseBytes?: number;
}): Promise<Hex> {
  const maxRequests = parameters.maxRequests ?? 4;
  if (!Number.isSafeInteger(maxRequests) || maxRequests < 1) {
    throw new Error("maxRequests must be a positive safe integer");
  }

  let call = parameters.call;
  for (let requestCount = 0; ; requestCount += 1) {
    try {
      return await parameters.ethCall(call);
    } catch (error) {
      const revertData = extractRevertData(error);
      if (revertData === undefined) throw error;
      if (requestCount >= maxRequests)
        throw new Error(`External request limit of ${maxRequests} exceeded`);

      let externalRequest;
      try {
        externalRequest = decodeExternalRequest(revertData);
      } catch {
        throw error;
      }

      assertSenderMatches({
        calledAddress: call.to,
        sender: externalRequest.sender,
      });
      const completed = await completeRequest({
        request: externalRequest.request,
        resolveRequirement: parameters.resolveRequirement,
      });
      await parameters.authorizeRequest({
        request: externalRequest.request,
        completedRequest: completed.request,
        requirements: completed.requirements,
      });
      const rawResponse = await executeHttpRequest({
        request: completed.request,
        ...(parameters.fetch === undefined ? {} : { fetch: parameters.fetch }),
        ...(parameters.maxResponseBytes === undefined
          ? {}
          : { maxResponseBytes: parameters.maxResponseBytes }),
      });

      const response = transformHttpResponse({
        response: rawResponse,
        transform: externalRequest.responseTransform,
      });

      call = {
        to: externalRequest.sender,
        data: encodeExternalRequestCallback({
          callbackFunction: externalRequest.callbackFunction,
          response,
          extraData: externalRequest.extraData,
        }),
      };
    }
  }
}

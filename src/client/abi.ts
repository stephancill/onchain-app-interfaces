import {
  decodeErrorResult,
  encodeAbiParameters,
  isAddressEqual,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";
import { z } from "zod";

import type { ExternalRequestData, HttpResponse } from "./types.ts";

const addressSchema = z.string().regex(/^0x[0-9a-fA-F]{40}$/);
const hexSchema = z.string().regex(/^0x(?:[0-9a-fA-F]{2})*$/);
const selectorSchema = z.string().regex(/^0x[0-9a-fA-F]{8}$/);

export const externalRequestAbi = [
  {
    type: "error",
    name: "ExternalRequest",
    inputs: [
      { name: "sender", type: "address" },
      {
        name: "request",
        type: "tuple",
        components: [
          { name: "url", type: "string" },
          { name: "method", type: "string" },
          {
            name: "headers",
            type: "tuple[]",
            components: [
              { name: "name", type: "string" },
              { name: "value", type: "string" },
            ],
          },
          { name: "body", type: "bytes" },
          {
            name: "requirements",
            type: "tuple[]",
            components: [
              { name: "location", type: "uint8" },
              { name: "path", type: "string" },
              { name: "description", type: "string" },
              { name: "sensitive", type: "bool" },
            ],
          },
        ],
      },
      { name: "callbackFunction", type: "bytes4" },
      { name: "extraData", type: "bytes" },
    ],
  },
] as const;

const callbackParameters = parseAbiParameters(
  "(uint16 status, (string name, string value)[] headers, bytes body) response, bytes extraData",
);

const externalRequestSchema = z.object({
  sender: addressSchema,
  request: z.object({
    url: z.string(),
    method: z.string(),
    headers: z.array(z.object({ name: z.string(), value: z.string() })),
    body: hexSchema,
    requirements: z.array(
      z.object({
        location: z.union([z.literal(0), z.literal(1), z.literal(2)]),
        path: z.string(),
        description: z.string(),
        sensitive: z.boolean(),
      }),
    ),
  }),
  callbackFunction: selectorSchema,
  extraData: hexSchema,
});

export function decodeExternalRequest(data: Hex): ExternalRequestData {
  const decoded = decodeErrorResult({ abi: externalRequestAbi, data });
  if (decoded.errorName !== "ExternalRequest") {
    throw new Error("Revert is not ExternalRequest");
  }

  const [sender, request, callbackFunction, extraData] = decoded.args;
  const parsed = externalRequestSchema.parse({
    sender,
    request,
    callbackFunction,
    extraData,
  });
  const locations = ["HEADER", "QUERY", "BODY"] as const;

  return {
    sender: parsed.sender as Address,
    request: {
      ...parsed.request,
      body: parsed.request.body as Hex,
      requirements: parsed.request.requirements.map((requirement) => ({
        ...requirement,
        location: locations[requirement.location],
      })),
    },
    callbackFunction: parsed.callbackFunction as Hex,
    extraData: parsed.extraData as Hex,
  };
}

export function encodeExternalRequestCallback(parameters: {
  callbackFunction: Hex;
  response: HttpResponse;
  extraData: Hex;
}): Hex {
  const encoded = encodeAbiParameters(callbackParameters, [
    {
      status: parameters.response.status,
      headers: parameters.response.headers,
      body: parameters.response.body,
    },
    parameters.extraData,
  ]);

  return `${parameters.callbackFunction}${encoded.slice(2)}`;
}

export function assertSenderMatches(parameters: {
  calledAddress: Address;
  sender: Address;
}): void {
  if (!isAddressEqual(parameters.calledAddress, parameters.sender)) {
    throw new Error("ExternalRequest sender does not match the called address");
  }
}

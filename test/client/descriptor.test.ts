import { describe, expect, test } from "bun:test";
import { encodeAbiParameters } from "viem";

import {
  decodeDescriptorResult,
  encodeDescriptorParameters,
  parseApplicationDescriptor,
} from "../../src/client/index.ts";

const actionJson = JSON.stringify({
  version: "0.1",
  kind: "action",
  name: "example.action",
  inputs: {
    encoding: "abi",
    fields: [
      {
        name: "parameters",
        abiType: "tuple",
        components: [
          {
            name: "slug",
            abiType: "string",
            minLength: 1,
            pattern: "^[a-z0-9-]+$",
          },
          { name: "quantity", abiType: "uint32", minimum: "1", maximum: "100" },
        ],
      },
    ],
  },
  output: { encoding: "preparedAction" },
  execution: { atomicity: "atomic-required" },
  effects: [
    {
      type: "decrease",
      assetField: "parameters.slug",
      amountField: "parameters.quantity",
    },
    {
      type: "increase",
      assetField: "parameters.quantity",
      chainIdField: "parameters.destinationChain",
      description: "cross-chain effect",
    },
  ],
});

describe("application descriptors", () => {
  test("encodes a dynamic struct without flattening it", () => {
    const descriptor = parseApplicationDescriptor(actionJson);
    const encoded = encodeDescriptorParameters({
      descriptor,
      values: { parameters: { slug: "test-drop", quantity: 2 } },
    });
    const expected = encodeAbiParameters(
      [
        {
          type: "tuple",
          components: [
            { name: "slug", type: "string" },
            { name: "quantity", type: "uint32" },
          ],
        },
      ],
      [{ slug: "test-drop", quantity: 2 }],
    );
    expect(encoded).toBe(expected);
  });

  test("preserves a chainIdField on an action effect", () => {
    const descriptor = parseApplicationDescriptor(actionJson);
    const effect =
      descriptor.kind === "action" ? descriptor.effects?.[1] : undefined;
    expect(effect?.chainIdField).toBe("parameters.destinationChain");
  });

  test("applies descriptor constraints before encoding", () => {
    const descriptor = parseApplicationDescriptor(actionJson);
    expect(() =>
      encodeDescriptorParameters({
        descriptor,
        values: { parameters: { slug: "invalid/path", quantity: 101 } },
      }),
    ).toThrow();
  });

  test("decodes named tuple results", () => {
    const descriptor = parseApplicationDescriptor(
      JSON.stringify({
        version: "0.1",
        kind: "query",
        name: "example.query",
        inputs: { encoding: "abi", fields: [] },
        output: {
          encoding: "abi",
          fields: [
            {
              name: "result",
              abiType: "tuple",
              components: [
                { name: "account", abiType: "address" },
                { name: "amount", abiType: "uint256" },
              ],
            },
          ],
        },
      }),
    );
    if (descriptor.kind !== "query")
      throw new Error("Expected query descriptor");
    const account = "0x000000000000000000000000000000000000beef";
    const data = encodeAbiParameters(
      [
        {
          type: "tuple",
          components: [
            { name: "account", type: "address" },
            { name: "amount", type: "uint256" },
          ],
        },
      ],
      [{ account, amount: 42n }],
    );
    expect(decodeDescriptorResult({ descriptor, data })).toEqual({
      result: {
        account: "0x000000000000000000000000000000000000bEEF",
        amount: 42n,
      },
    });
  });

  test("decodes a JSON-content bytes field into an object", () => {
    const descriptor = parseApplicationDescriptor(
      JSON.stringify({
        version: "0.1",
        kind: "query",
        name: "example.json",
        inputs: { encoding: "abi", fields: [] },
        output: {
          encoding: "abi",
          fields: [
            {
              name: "result",
              abiType: "tuple",
              components: [
                { name: "status", abiType: "uint16" },
                {
                  name: "body",
                  abiType: "bytes",
                  contentType: "application/json",
                  sensitivity: "public",
                },
              ],
            },
          ],
        },
      }),
    );
    if (descriptor.kind !== "query")
      throw new Error("Expected query descriptor");
    const body = JSON.stringify({ ok: true, data: [{ name: "ETH/USD" }] });
    const data = encodeAbiParameters(
      [
        {
          type: "tuple",
          components: [
            { name: "status", type: "uint16" },
            { name: "body", type: "bytes" },
          ],
        },
      ],
      [{ status: 200, body: `0x${Buffer.from(body).toString("hex")}` }],
    );
    const decoded = decodeDescriptorResult({ descriptor, data });
    expect(decoded.result).toEqual({
      status: 200,
      body: JSON.parse(body),
    });
  });

  test("rejects unknown versions and ABI types", () => {
    expect(() =>
      parseApplicationDescriptor(actionJson.replace('"0.1"', '"1.0"')),
    ).toThrow();
    expect(() =>
      parseApplicationDescriptor(actionJson.replace('"uint32"', '"uint7"')),
    ).toThrow("Unsupported descriptor ABI type");
  });
});

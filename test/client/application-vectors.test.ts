import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  decodeAbiParameters,
  encodeAbiParameters,
  keccak256,
  stringToHex,
  toFunctionSelector,
} from "viem";

import {
  encodeDescriptorParameters,
  parseApplicationDescriptor,
  stringifyJson,
} from "../../src/client/index.ts";

type Vectors = {
  keccak: { empty: `0x${string}`; abc: `0x${string}` };
  selectors: {
    queries: `0x${string}`;
    actions: `0x${string}`;
    queryDescriptor: `0x${string}`;
    actionDescriptor: `0x${string}`;
    query: `0x${string}`;
    prepare: `0x${string}`;
  };
  descriptor: unknown;
  values: Record<string, unknown>;
  encodedParameters: `0x${string}`;
  preparedAction: `0x${string}`;
};

const vectors = JSON.parse(
  readFileSync(
    new URL("../vectors/application-client.json", import.meta.url),
    "utf8",
  ),
) as Vectors;

describe("shared application client vectors", () => {
  test("matches Ethereum hashes and interface selectors", () => {
    expect(keccak256("0x")).toBe(vectors.keccak.empty);
    expect(keccak256(stringToHex("abc"))).toBe(vectors.keccak.abc);
    expect(toFunctionSelector("queries()")).toBe(vectors.selectors.queries);
    expect(toFunctionSelector("actions()")).toBe(vectors.selectors.actions);
    expect(toFunctionSelector("queryDescriptor(bytes32)")).toBe(
      vectors.selectors.queryDescriptor,
    );
    expect(toFunctionSelector("actionDescriptor(bytes32)")).toBe(
      vectors.selectors.actionDescriptor,
    );
    expect(toFunctionSelector("query(bytes32,bytes)")).toBe(
      vectors.selectors.query,
    );
    expect(toFunctionSelector("prepare(bytes32,address,bytes)")).toBe(
      vectors.selectors.prepare,
    );
  });

  test("matches descriptor and PreparedAction encoding", () => {
    const descriptor = parseApplicationDescriptor(
      JSON.stringify(vectors.descriptor),
    );
    expect(
      encodeDescriptorParameters({ descriptor, values: vectors.values }),
    ).toBe(vectors.encodedParameters);

    const decoded = decodeAbiParameters(
      [
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
      vectors.preparedAction,
    );
    expect(decoded[0].validUntil).toBe(99n);
    expect(decoded[0].calls[0]?.value).toBe(42n);
    expect(
      encodeAbiParameters(
        [
          {
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
        [decoded[0]],
      ),
    ).toBe(vectors.preparedAction);
  });

  test("serializes bigints as decimal strings", () => {
    expect(stringifyJson({ value: 42n }, 0)).toBe('{"value":"42"}');
  });
});

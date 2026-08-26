import { describe, expect, test } from "bun:test";
import { encodeAbiParameters, getAddress, stringToHex } from "viem";

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

  test("applies descriptor constraints before encoding", () => {
    const descriptor = parseApplicationDescriptor(actionJson);
    expect(() =>
      encodeDescriptorParameters({
        descriptor,
        values: { parameters: { slug: "invalid/path", quantity: 101 } },
      }),
    ).toThrow();
  });

  test("encodes scalar arrays and empty arrays", () => {
    const descriptor = parseApplicationDescriptor(
      JSON.stringify({
        version: "0.1",
        kind: "action",
        name: "example.arrays",
        inputs: {
          encoding: "abi",
          fields: [
            {
              name: "amounts",
              abiType: "uint32[]",
              minimum: "1",
              maxItems: 3,
            },
            { name: "labels", abiType: "string[]" },
          ],
        },
        output: { encoding: "preparedAction" },
      }),
    );
    const encoded = encodeDescriptorParameters({
      descriptor,
      values: { amounts: [1, "2", 3n], labels: [] },
    });
    expect(encoded).toBe(
      encodeAbiParameters(
        [{ type: "uint32[]" }, { type: "string[]" }],
        [[1, 2, 3], []],
      ),
    );
  });

  test("encodes tuple arrays with recursively normalized elements", () => {
    const descriptor = parseApplicationDescriptor(
      JSON.stringify({
        version: "0.1",
        kind: "action",
        name: "example.tuple-array",
        inputs: {
          encoding: "abi",
          fields: [
            {
              name: "entries",
              abiType: "tuple[]",
              components: [
                { name: "account", abiType: "address" },
                {
                  name: "detail",
                  abiType: "tuple",
                  components: [{ name: "amount", abiType: "uint32" }],
                },
              ],
            },
          ],
        },
        output: { encoding: "preparedAction" },
      }),
    );
    const account = "0x000000000000000000000000000000000000beef";
    const encoded = encodeDescriptorParameters({
      descriptor,
      values: { entries: [{ account, detail: { amount: "42" } }] },
    });
    expect(encoded).toBe(
      encodeAbiParameters(
        [
          {
            type: "tuple[]",
            components: [
              { name: "account", type: "address" },
              {
                name: "detail",
                type: "tuple",
                components: [{ name: "amount", type: "uint32" }],
              },
            ],
          },
        ],
        [[{ account, detail: { amount: 42 } }]],
      ),
    );
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

  test("decodes named tuple arrays recursively", () => {
    const descriptor = parseApplicationDescriptor(
      JSON.stringify({
        version: "0.1",
        kind: "query",
        name: "example.tuple-array-query",
        inputs: { encoding: "abi", fields: [] },
        output: {
          encoding: "abi",
          fields: [
            {
              name: "results",
              abiType: "tuple[]",
              components: [
                { name: "label", abiType: "string" },
                {
                  name: "detail",
                  abiType: "tuple",
                  components: [{ name: "amount", abiType: "uint256" }],
                },
              ],
            },
          ],
        },
      }),
    );
    if (descriptor.kind !== "query")
      throw new Error("Expected query descriptor");
    const data = encodeAbiParameters(
      [
        {
          type: "tuple[]",
          components: [
            { name: "label", type: "string" },
            {
              name: "detail",
              type: "tuple",
              components: [{ name: "amount", type: "uint256" }],
            },
          ],
        },
      ],
      [[{ label: "one", detail: { amount: 1n } }]],
    );
    expect(decodeDescriptorResult({ descriptor, data })).toEqual({
      results: [{ label: "one", detail: { amount: 1n } }],
    });
  });

  test("enforces maximum items on decoded output arrays", () => {
    const descriptor = parseApplicationDescriptor(
      JSON.stringify({
        version: "0.1",
        kind: "query",
        name: "example.bounded-output",
        inputs: { encoding: "abi", fields: [] },
        output: {
          encoding: "abi",
          fields: [{ name: "items", abiType: "uint256[]", maxItems: 1 }],
        },
      }),
    );
    if (descriptor.kind !== "query")
      throw new Error("Expected query descriptor");
    const data = encodeAbiParameters([{ type: "uint256[]" }], [[1n, 2n]]);
    expect(() => decodeDescriptorResult({ descriptor, data })).toThrow(
      "items exceeds its maximum items",
    );
  });

  test("enforces minimum items recursively on decoded output arrays", () => {
    const descriptor = parseApplicationDescriptor(
      JSON.stringify({
        version: "0.1",
        kind: "query",
        name: "example.nested-bounded-output",
        inputs: { encoding: "abi", fields: [] },
        output: {
          encoding: "abi",
          fields: [
            {
              name: "result",
              abiType: "tuple",
              components: [{ name: "items", abiType: "bool[]", minItems: 1 }],
            },
          ],
        },
      }),
    );
    if (descriptor.kind !== "query")
      throw new Error("Expected query descriptor");
    const data = encodeAbiParameters(
      [
        {
          type: "tuple",
          components: [{ name: "items", type: "bool[]" }],
        },
      ],
      [{ items: [] }],
    );
    expect(() => decodeDescriptorResult({ descriptor, data })).toThrow(
      "items has fewer than its minimum items",
    );
  });

  test("enforces array item bounds", () => {
    const descriptor = parseApplicationDescriptor(
      JSON.stringify({
        version: "0.1",
        kind: "action",
        name: "example.bounded-array",
        inputs: {
          encoding: "abi",
          fields: [
            { name: "items", abiType: "bool[]", minItems: 1, maxItems: 2 },
          ],
        },
        output: { encoding: "preparedAction" },
      }),
    );
    expect(() =>
      encodeDescriptorParameters({ descriptor, values: { items: [] } }),
    ).toThrow("fewer than its minimum items");
    expect(() =>
      encodeDescriptorParameters({
        descriptor,
        values: { items: [true, false, true] },
      }),
    ).toThrow("exceeds its maximum items");
    expect(() =>
      encodeDescriptorParameters({ descriptor, values: { items: true } }),
    ).toThrow("Invalid array value");
  });

  test("rejects invalid array descriptors and components", () => {
    const descriptorFor = (field: Record<string, unknown>) =>
      JSON.stringify({
        version: "0.1",
        kind: "action",
        name: "example.invalid-array",
        inputs: { encoding: "abi", fields: [field] },
        output: { encoding: "preparedAction" },
      });

    expect(() =>
      parseApplicationDescriptor(
        descriptorFor({ name: "items", abiType: "uint256[][]" }),
      ),
    ).toThrow("Unsupported descriptor ABI type");
    expect(() =>
      parseApplicationDescriptor(
        descriptorFor({ name: "items", abiType: "uint256[2]" }),
      ),
    ).toThrow("Unsupported descriptor ABI type");
    expect(() =>
      parseApplicationDescriptor(
        descriptorFor({ name: "items", abiType: "tuple[]" }),
      ),
    ).toThrow("Tuple fields require components");
    expect(() =>
      parseApplicationDescriptor(
        descriptorFor({
          name: "items",
          abiType: "uint256[]",
          components: [],
        }),
      ),
    ).toThrow("Only tuple fields may have components");
    expect(() =>
      parseApplicationDescriptor(
        descriptorFor({ name: "items", abiType: "uint256", minItems: 1 }),
      ),
    ).toThrow("Only array fields may have item constraints");
    expect(() =>
      parseApplicationDescriptor(
        descriptorFor({
          name: "items",
          abiType: "uint256[]",
          minItems: 2,
          maxItems: 1,
        }),
      ),
    ).toThrow("minItems exceeds maxItems");
    expect(() =>
      parseApplicationDescriptor(
        descriptorFor({ name: "items", abiType: "uint256[]", minItems: -1 }),
      ),
    ).toThrow();
  });

  test("rejects duplicate nested tuple component names", () => {
    const descriptorFor = (abiType: "tuple" | "tuple[]") =>
      JSON.stringify({
        version: "0.1",
        kind: "action",
        name: "example.duplicate-components",
        inputs: {
          encoding: "abi",
          fields: [
            {
              name: "value",
              abiType,
              components: [
                { name: "duplicate", abiType: "bool" },
                { name: "duplicate", abiType: "uint256" },
              ],
            },
          ],
        },
        output: { encoding: "preparedAction" },
      });

    expect(() => parseApplicationDescriptor(descriptorFor("tuple"))).toThrow(
      "Duplicate field: duplicate",
    );
    expect(() => parseApplicationDescriptor(descriptorFor("tuple[]"))).toThrow(
      "Duplicate field: duplicate",
    );
  });

  test("rejects unknown versions and ABI types", () => {
    expect(() =>
      parseApplicationDescriptor(actionJson.replace('"0.1"', '"1.0"')),
    ).toThrow();
    expect(() =>
      parseApplicationDescriptor(actionJson.replace('"uint32"', '"uint7"')),
    ).toThrow("Unsupported descriptor ABI type");
  });

  describe("json query outputs", () => {
    const jsonDescriptorJson = JSON.stringify({
      version: "0.1",
      kind: "query",
      name: "example.json-query",
      inputs: {
        encoding: "abi",
        fields: [{ name: "account", abiType: "address" }],
      },
      output: {
        encoding: "json",
        fields: [
          { name: "owner", abiType: "address", equalsInput: "account" },
          {
            name: "positions",
            abiType: "tuple[]",
            maxItems: 2,
            path: "data.positions[]",
            components: [
              { name: "trader", abiType: "address", equalsInput: "account" },
              { name: "pairIndex", abiType: "uint256" },
              { name: "buy", abiType: "bool" },
              { name: "collateral", abiType: "uint256" },
            ],
          },
          { name: "label", abiType: "string" },
          { name: "blockNumber", abiType: "uint256", path: "block" },
        ],
      },
    });
    const account = "0x000000000000000000000000000000000000beef";
    const body = JSON.parse(
      JSON.stringify({
        owner: account,
        data: {
          positions: [
            {
              trader: account,
              pairIndex: 62,
              buy: false,
              collateral: "2000000000",
            },
          ],
        },
        label: "live",
        block: 35_961_058,
      }),
    );

    test("extracts typed values from a JSON body", () => {
      const descriptor = parseApplicationDescriptor(jsonDescriptorJson);
      if (descriptor.kind !== "query") throw new Error("expected query");
      const result = decodeDescriptorResult({
        descriptor,
        data: stringToHex(JSON.stringify(body)),
        inputValues: { account },
      });
      expect(result.owner).toBe(getAddress(account));
      expect(result.label).toBe("live");
      expect(result.blockNumber).toBe(35_961_058n);
      expect(result.positions).toEqual([
        {
          trader: getAddress(account),
          pairIndex: 62n,
          buy: false,
          collateral: 2_000_000_000n,
        },
      ]);
    });

    test("rejects bound values that differ from the input", () => {
      const descriptor = parseApplicationDescriptor(jsonDescriptorJson);
      if (descriptor.kind !== "query") throw new Error("expected query");
      const tampered = structuredClone(body);
      tampered.data.positions[0].trader =
        "0x000000000000000000000000000000000000dead";
      expect(() =>
        decodeDescriptorResult({
          descriptor,
          data: stringToHex(JSON.stringify(tampered)),
          inputValues: { account },
        }),
      ).toThrow("does not match its bound input value");
    });

    test("requires input values when the descriptor declares bindings", () => {
      const descriptor = parseApplicationDescriptor(jsonDescriptorJson);
      if (descriptor.kind !== "query") throw new Error("expected query");
      expect(() =>
        decodeDescriptorResult({
          descriptor,
          data: stringToHex(JSON.stringify(body)),
        }),
      ).toThrow("requires input values");
    });

    test("enforces maximum items on extracted arrays", () => {
      const descriptor = parseApplicationDescriptor(jsonDescriptorJson);
      if (descriptor.kind !== "query") throw new Error("expected query");
      const oversized = structuredClone(body);
      oversized.data.positions.push(
        { ...oversized.data.positions[0] },
        { ...oversized.data.positions[0] },
      );
      expect(() =>
        decodeDescriptorResult({
          descriptor,
          data: stringToHex(JSON.stringify(oversized)),
          inputValues: { account },
        }),
      ).toThrow("exceeds its maximum items");
    });

    test("rejects missing JSON keys and non-array selections", () => {
      const descriptor = parseApplicationDescriptor(jsonDescriptorJson);
      if (descriptor.kind !== "query") throw new Error("expected query");
      expect(() =>
        decodeDescriptorResult({
          descriptor,
          data: stringToHex(JSON.stringify({})),
          inputValues: { account },
        }),
      ).toThrow("missing key");
      const scalarSelection = structuredClone(body);
      scalarSelection.data.positions = 3;
      expect(() =>
        decodeDescriptorResult({
          descriptor,
          data: stringToHex(JSON.stringify(scalarSelection)),
          inputValues: { account },
        }),
      ).toThrow("Invalid array value");
    });

    test("rejects invalid path syntax and unknown bindings at parse time", () => {
      const withPath = (field: Record<string, unknown>) =>
        parseApplicationDescriptor(
          JSON.stringify({
            version: "0.1",
            kind: "query",
            name: "example.bad-path",
            inputs: {
              encoding: "abi",
              fields: [{ name: "account", abiType: "address" }],
            },
            output: {
              encoding: "json",
              fields: [{ name: "value", abiType: "uint256", ...field }],
            },
          }),
        );
      expect(() => withPath({ path: "a[]b" })).toThrow(
        "Invalid JSON path segment",
      );
      expect(() => withPath({ path: "a[].b[]" })).toThrow(
        "more than one [] path segment",
      );
      expect(() =>
        withPath({ path: "a[]", abiType: "uint256[]" }),
      ).not.toThrow();
      expect(() => withPath({ equalsInput: "missing" })).toThrow(
        "binds to unknown input",
      );
    });

    test("rejects JSON-only properties on abi outputs", () => {
      expect(() =>
        parseApplicationDescriptor(
          JSON.stringify({
            version: "0.1",
            kind: "query",
            name: "example.abi-with-path",
            inputs: { encoding: "abi", fields: [] },
            output: {
              encoding: "abi",
              fields: [{ name: "value", abiType: "uint256", path: "value" }],
            },
          }),
        ),
      ).toThrow("JSON-only properties");
    });
  });
});

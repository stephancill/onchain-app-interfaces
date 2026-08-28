import { describe, expect, test } from "bun:test";
import { keccak256, stringToHex } from "viem";

import { transformHttpResponse } from "../../src/client/index.ts";
import type { JsonAbiNode, ResponseTransform } from "../../src/client/types.ts";

function node(
  nodeType: JsonAbiNode["nodeType"],
  pointer: string,
  childCount: number,
  maxItems: number,
): JsonAbiNode {
  return { nodeType, pointer, childCount, maxItems };
}

function jsonTransform(nodes: JsonAbiNode[]): ResponseTransform {
  return {
    kind: "JSON_ABI",
    statusFrom: 200,
    statusTo: 299,
    nodes,
  };
}

function targetTransactionTransform(): ResponseTransform {
  return jsonTransform([
    node("TUPLE", "", 5, 0),
    node("UINT256_DECIMAL", "/data/chainId", 0, 0),
    node("ADDRESS", "/data/to", 0, 0),
    node("ADDRESS", "/data/from", 0, 0),
    node("UINT256_HEX", "/data/value", 0, 0),
    node("BYTES", "/data/data", 0, 0),
  ]);
}

function targetPositionsTransform(): ResponseTransform {
  return jsonTransform([
    node("TUPLE", "", 2, 0),
    node("ARRAY", "/data/trades", 1, 40),
    node("TUPLE", "", 2, 0),
    node("ADDRESS", "/trade/trader", 0, 0),
    node("UINT256_DECIMAL", "/trade/pairIndex", 0, 0),
    node("ARRAY", "/data/orders", 1, 40),
    node("STRING", "/order/symbol", 0, 0),
  ]);
}

function rawResponse(
  body: object,
): Parameters<typeof transformHttpResponse>[0]["response"] {
  const hex = stringToHex(JSON.stringify(body));
  return {
    status: 200,
    headers: [{ name: "content-type", value: "application/json" }],
    rawBodyHash: keccak256(hex),
    bodyEncoding: "RAW",
    body: hex,
  };
}

describe("response transform", () => {
  test("projects a transaction envelope into ABI", () => {
    const response = rawResponse({
      ok: true,
      data: {
        chainId: 8453,
        to: "0x44914408af82bc9983bbb330e3578e1105e11d4e",
        from: "0x1111111111111111111111111111111111111111",
        value: "0x1",
        data: "0x1234",
      },
    });
    const projected = transformHttpResponse({
      response,
      transform: targetTransactionTransform(),
    });

    expect(projected.bodyEncoding).toBe("JSON_ABI");
    expect(projected.rawBodyHash).toBe(response.rawBodyHash);
    // ABI-encoded tuple where the trailing bytes member is dynamic.
    expect(projected.body.length).toBeGreaterThan(258);
    expect(projected.body.length % 64).toBe(2);
  });

  test("projects arrays of tuples and scalar arrays", () => {
    const response = rawResponse({
      data: {
        trades: [
          {
            trade: {
              trader: "0x1111111111111111111111111111111111111111",
              pairIndex: "1",
            },
          },
        ],
        orders: [{ order: { symbol: "ETH/USD" } }],
      },
    });
    const projected = transformHttpResponse({
      response,
      transform: targetPositionsTransform(),
    });

    expect(projected.bodyEncoding).toBe("JSON_ABI");
    expect(projected.body.length).toBeGreaterThan(2);
  });

  test("keeps out-of-range status raw", () => {
    const hex = stringToHex('{"error":"bad"}');
    const response = {
      status: 400,
      headers: [{ name: "content-type", value: "application/json" }] as {
        name: string;
        value: string;
      }[],
      rawBodyHash: keccak256(hex),
      bodyEncoding: "RAW" as const,
      body: hex,
    };
    const projected = transformHttpResponse({
      response,
      transform: targetTransactionTransform(),
    });

    expect(projected.bodyEncoding).toBe("RAW");
    expect(projected.body).toBe(hex);
  });

  test("passes RAW transforms through unchanged", () => {
    const hex = stringToHex("plain");
    const response = {
      status: 200,
      headers: [] as { name: string; value: string }[],
      rawBodyHash: keccak256(hex),
      bodyEncoding: "RAW" as const,
      body: hex,
    };
    const projected = transformHttpResponse({
      response,
      transform: { kind: "RAW", statusFrom: 0, statusTo: 0, nodes: [] },
    });

    expect(projected.bodyEncoding).toBe("RAW");
    expect(projected.body).toBe(hex);
  });

  test("rejects duplicate JSON object keys", () => {
    const hex = stringToHex('{"data":{"a":1,"a":2}}');
    expect(() =>
      transformHttpResponse({
        response: {
          status: 200,
          headers: [{ name: "content-type", value: "application/json" }],
          rawBodyHash: keccak256(hex),
          bodyEncoding: "RAW",
          body: hex,
        },
        transform: targetTransactionTransform(),
      }),
    ).toThrow("Duplicate JSON object key");
  });

  test("rejects incomplete projection trees", () => {
    expect(() =>
      transformHttpResponse({
        response: rawResponse({ ok: true }),
        transform: jsonTransform([
          node("TUPLE", "", 2, 0),
          node("BOOL", "/ok", 0, 0),
        ]),
      }),
    ).toThrow("Incomplete projection tree");
  });

  test("rejects arrays that exceed maxItems", () => {
    const response = rawResponse({
      data: {
        trades: [
          {
            trade: {
              trader: "0x1111111111111111111111111111111111111111",
              pairIndex: "1",
            },
          },
        ],
      },
    });
    const overLimit = jsonTransform([
      node("ARRAY", "/data/trades", 1, 0),
      node("UINT256_DECIMAL", "/trade/pairIndex", 0, 0),
    ]);
    expect(() =>
      transformHttpResponse({ response, transform: overLimit }),
    ).toThrow("Invalid projection array limit");
  });

  test("fails on a missing field", () => {
    const response = rawResponse({});
    expect(() =>
      transformHttpResponse({
        response,
        transform: targetTransactionTransform(),
      }),
    ).toThrow("JSON Pointer does not exist");
  });
});

import { describe, expect, test } from "bun:test";
import { encodeErrorResult, stringToHex, type Address, type Hex } from "viem";

import { externalRequestAbi, resolveCall } from "../../src/client/index.ts";

const resolver = "0x0000000000000000000000000000000000001234" as Address;
const attacker = "0x0000000000000000000000000000000000009999" as Address;
const callbackFunction = "0x12345678" as Hex;

function externalRequest(sender: Address = resolver): Hex {
  return encodeErrorResult({
    abi: externalRequestAbi,
    errorName: "ExternalRequest",
    args: [
      sender,
      {
        url: "https://api.example.com/quote",
        method: "POST",
        headers: [{ name: "Content-Type", value: "application/json" }],
        body: stringToHex('{"asset":"ETH"}'),
        requirements: [
          {
            location: 0,
            path: "Authorization",
            description: "credential",
            sensitive: true,
          },
        ],
      },
      {
        kind: 0,
        statusFrom: 0,
        statusTo: 0,
        nodes: [],
      },
      callbackFunction,
      "0x1122",
    ],
  });
}

describe("resolveCall", () => {
  test("continues an ExternalRequest callback", async () => {
    const calls: Hex[] = [];
    let authorized = false;

    const result = await resolveCall({
      call: { to: resolver, data: "0xabcdef12" },
      ethCall: ({ data }) => {
        calls.push(data);
        if (calls.length === 1) throw { data: externalRequest() };
        return Promise.resolve("0xcafe");
      },
      resolveRequirement: () => "Bearer secret",
      authorizeRequest: ({ completedRequest, requirements }) => {
        authorized = true;
        expect(completedRequest.headers.at(-1)?.name).toBe("Authorization");
        expect(requirements[0]?.requirement.sensitive).toBe(true);
      },
      fetch: async (_url, init) => {
        expect(authorized).toBe(true);
        expect(init?.redirect).toBe("manual");
        return new Response("quote", {
          status: 200,
          headers: { "X-Quote": "fixture" },
        });
      },
    });

    expect(result).toBe("0xcafe");
    expect(calls).toHaveLength(2);
    expect(calls[1]?.startsWith(callbackFunction)).toBe(true);
  });

  test("supports recursive external requests", async () => {
    let callCount = 0;
    let requestCount = 0;

    const result = await resolveCall({
      call: { to: resolver, data: "0xabcdef12" },
      ethCall: () => {
        callCount += 1;
        if (callCount <= 2) throw { data: externalRequest() };
        return Promise.resolve("0xbeef");
      },
      resolveRequirement: () => "Bearer secret",
      authorizeRequest: () => {},
      fetch: async () => {
        requestCount += 1;
        return new Response(`response ${requestCount}`);
      },
    });

    expect(result).toBe("0xbeef");
    expect(requestCount).toBe(2);
    expect(callCount).toBe(3);
  });

  test("rejects a mismatched sender before HTTP execution", async () => {
    let fetched = false;
    const resolution = resolveCall({
      call: { to: resolver, data: "0xabcdef12" },
      ethCall: () => {
        throw { data: externalRequest(attacker) };
      },
      resolveRequirement: () => "secret",
      authorizeRequest: () => {},
      fetch: async () => {
        fetched = true;
        return new Response();
      },
    });

    expect(resolution).rejects.toThrow("does not match");
    await resolution.catch(() => undefined);
    expect(fetched).toBe(false);
  });

  test("requires authorization before HTTP execution", async () => {
    let fetched = false;
    const resolution = resolveCall({
      call: { to: resolver, data: "0xabcdef12" },
      ethCall: () => {
        throw { data: externalRequest() };
      },
      resolveRequirement: () => "secret",
      authorizeRequest: () => {
        throw new Error("origin denied");
      },
      fetch: async () => {
        fetched = true;
        return new Response();
      },
    });

    expect(resolution).rejects.toThrow("origin denied");
    await resolution.catch(() => undefined);
    expect(fetched).toBe(false);
  });
});

import { describe, expect, test } from "bun:test";
import { stringToHex } from "viem";

import { completeRequest, validateRequest } from "../../src/client/index.ts";
import type { HttpRequest } from "../../src/client/types.ts";

function request(overrides: Partial<HttpRequest> = {}): HttpRequest {
  return {
    url: "https://api.example.com/quote?market=eth",
    method: "POST",
    headers: [
      { name: "Content-Type", value: "application/json; charset=utf-8" },
    ],
    body: stringToHex('{"asset":"ETH","credentials":{}}'),
    requirements: [],
    ...overrides,
  };
}

describe("completeRequest", () => {
  test("inserts header, query, and JSON string requirements deterministically", async () => {
    const completed = await completeRequest({
      request: request({
        requirements: [
          {
            location: "HEADER",
            path: "Authorization",
            description: "credential",
            sensitive: true,
          },
          {
            location: "QUERY",
            path: "account_id",
            description: "account",
            sensitive: false,
          },
          {
            location: "BODY",
            path: "/credentials/api~1key",
            description: "API key",
            sensitive: true,
          },
        ],
      }),
      resolveRequirement: ({ requirement }) =>
        ({
          Authorization: "Bearer secret",
          account_id: "account 1",
          "/credentials/api~1key": "key",
        })[requirement.path] ?? "",
    });

    expect(completed.request.url).toBe(
      "https://api.example.com/quote?market=eth&account_id=account+1",
    );
    expect(completed.request.headers.at(-1)).toEqual({
      name: "Authorization",
      value: "Bearer secret",
    });
    expect(
      new TextDecoder().decode(
        Buffer.from(completed.request.body.slice(2), "hex"),
      ),
    ).toBe('{"asset":"ETH","credentials":{"api/key":"key"}}');
  });

  test("appends a form requirement", async () => {
    const completed = await completeRequest({
      request: request({
        headers: [
          { name: "Content-Type", value: "application/x-www-form-urlencoded" },
        ],
        body: stringToHex("asset=ETH"),
        requirements: [
          {
            location: "BODY",
            path: "api_key",
            description: "API key",
            sensitive: true,
          },
        ],
      }),
      resolveRequirement: () => "a secret/value",
    });

    expect(
      new TextDecoder().decode(
        Buffer.from(completed.request.body.slice(2), "hex"),
      ),
    ).toBe("asset=ETH&api_key=a+secret%2Fvalue");
  });
});

describe("validateRequest", () => {
  test("rejects insecure URLs", () => {
    expect(() =>
      validateRequest(request({ url: "http://api.example.com" })),
    ).toThrow("HTTPS");
  });

  test("rejects case-insensitive duplicate header targets", () => {
    expect(() =>
      validateRequest(
        request({
          headers: [{ name: "authorization", value: "public" }],
          requirements: [
            {
              location: "HEADER",
              path: "Authorization",
              description: "credential",
              sensitive: true,
            },
          ],
        }),
      ),
    ).toThrow("already present");
  });

  test("rejects missing JSON parents", async () => {
    expect(
      completeRequest({
        request: request({
          requirements: [
            {
              location: "BODY",
              path: "/missing/key",
              description: "value",
              sensitive: false,
            },
          ],
        }),
        resolveRequirement: () => "value",
      }),
    ).rejects.toThrow("parent does not exist");
  });
});

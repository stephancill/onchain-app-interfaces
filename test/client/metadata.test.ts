import { describe, expect, test } from "bun:test";
import { encodeFunctionResult } from "viem";

import {
  contractMetadataAbi,
  maxMetadataBytes,
  maxMetadataUriBytes,
  readContractMetadata,
  resolveContractMetadata,
} from "../../src/client/index.ts";
import vectors from "../vectors/contract-metadata.json";

const metadata = { name: "Example", description: "Read positions." };

describe("required contract metadata", () => {
  for (const vector of vectors.valid) {
    test(vector.label, async () => {
      const result = await resolveContractMetadata({ uri: vector.uri });
      expect(result).toEqual({ uri: vector.uri, metadata: vector.metadata });
    });
  }
  for (const vector of vectors.invalid) {
    test(`rejects ${vector.label}`, async () => {
      await expect(
        resolveContractMetadata({ uri: vector.uri }),
      ).rejects.toThrow("Invalid application metadata");
    });
  }

  test("enforces URI and decoded document bounds", async () => {
    await expect(
      resolveContractMetadata({ uri: "x".repeat(maxMetadataUriBytes + 1) }),
    ).rejects.toThrow("size limit");
    const body = JSON.stringify({
      ...metadata,
      description: "x".repeat(maxMetadataBytes),
    });
    for (const uri of [
      `data:application/json,${body}`,
      `data:application/json;base64,${btoa(body)}`,
    ])
      await expect(resolveContractMetadata({ uri })).rejects.toThrow(
        "Invalid application metadata",
      );
  });

  test("reads the ABI string rather than interpreting return data as JSON", async () => {
    const uri = vectors.valid[0]!.uri;
    const result = await readContractMetadata({
      address: "0x0000000000000000000000000000000000000001",
      ethCall: async () =>
        encodeFunctionResult({
          abi: contractMetadataAbi,
          functionName: "contractURI",
          result: uri,
        }),
    });
    expect(result.metadata).toEqual(vectors.valid[0]!.metadata);
  });

  test("reports missing ABI data and RPC failures distinctly", async () => {
    const address = "0x0000000000000000000000000000000000000001" as const;
    await expect(
      readContractMetadata({ address, ethCall: async () => "0x" }),
    ).rejects.toThrow("missing or malformed");
    await expect(
      readContractMetadata({
        address,
        ethCall: async () => {
          throw new Error("RPC unavailable");
        },
      }),
    ).rejects.toThrow("call failed");
  });

  test("authorizes a remote GET before fetching and disables redirects and credentials", async () => {
    let authorized = false;
    const result = await resolveContractMetadata({
      uri: "https://example.com/metadata.json",
      authorizeRequest: ({ completedRequest }) => {
        expect(completedRequest.method).toBe("GET");
        expect(completedRequest.url).toBe("https://example.com/metadata.json");
        authorized = true;
      },
      fetch: async (_input, init) => {
        expect(authorized).toBe(true);
        expect(init?.redirect).toBe("manual");
        expect(init?.credentials).toBe("omit");
        return Response.json(metadata);
      },
    });
    expect(result.metadata).toEqual(metadata);
  });

  test("requires remote authorization without fetching", async () => {
    let fetched = false;
    await expect(
      resolveContractMetadata({
        uri: "https://example.com/metadata.json",
        fetch: async () => {
          fetched = true;
          return Response.json(metadata);
        },
      }),
    ).rejects.toThrow("network authorization");
    expect(fetched).toBe(false);
  });

  test("rejects redirects, HTTP errors, oversize bodies and invalid remote documents", async () => {
    for (const status of [302, 404, 500])
      await expect(
        resolveContractMetadata({
          uri: "https://example.com/metadata.json",
          authorizeRequest: () => {},
          fetch: async () => new Response("{}", { status }),
        }),
      ).rejects.toThrow("Metadata resolution failed");
    await expect(
      resolveContractMetadata({
        uri: "https://example.com/metadata.json",
        authorizeRequest: () => {},
        fetch: async () => new Response("x".repeat(maxMetadataBytes + 1)),
      }),
    ).rejects.toThrow("exceeds");
    await expect(
      resolveContractMetadata({
        uri: "https://example.com/metadata.json",
        authorizeRequest: () => {},
        fetch: async () => Response.json({ name: "Example" }),
      }),
    ).rejects.toThrow("Invalid application metadata document");
  });

  test("uses the configured IPFS gateway and preserves CID case", async () => {
    const result = await resolveContractMetadata({
      uri: "ipfs://QmExample/path%20name.json",
      ipfsGateway: "https://gateway.example",
      authorizeRequest: ({ completedRequest }) => {
        expect(completedRequest.url).toBe(
          "https://gateway.example/ipfs/QmExample/path%20name.json",
        );
      },
      fetch: async () => Response.json(metadata),
    });
    expect(result.metadata).toEqual(metadata);
    for (const uri of [
      "ipfs://QmExample/../secret",
      "ipfs://QmExample/%2fsecret",
      "file:///etc/passwd",
    ])
      await expect(
        resolveContractMetadata({
          uri,
          ipfsGateway: "https://gateway.example",
        }),
      ).rejects.toThrow("Metadata resolution failed");
    await expect(
      resolveContractMetadata({ uri: "ipfs://QmExample" }),
    ).rejects.toThrow("configured HTTPS gateway");
  });
});

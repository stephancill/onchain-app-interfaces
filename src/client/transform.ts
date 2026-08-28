import {
  encodeAbiParameters,
  getAddress,
  isAddress,
  keccak256,
  size,
  type AbiParameter,
  type Hex,
} from "viem";

import type {
  HttpResponse,
  JsonAbiNode,
  ResponseBodyEncoding,
  ResponseTransform,
} from "./types.ts";

const MAX_JSON_DEPTH = 64;
const MAX_NODES = 128;
const MAX_TOTAL_VALUES = 4096;
const MAX_PROJECTED_BYTES = 1_048_576;

type JsonValue =
  | string
  | bigint
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

function parseJsonStrict(body: Hex): JsonValue {
  const bytes = new TextDecoder().decode(
    Uint8Array.from(body.slice(2).match(/../g) ?? [], (byte) =>
      Number.parseInt(byte, 16),
    ),
  );
  let cursor = 0;

  function skipWhitespace(): void {
    while (
      cursor < bytes.length &&
      (bytes[cursor] === " " ||
        bytes[cursor] === "\t" ||
        bytes[cursor] === "\n" ||
        bytes[cursor] === "\r")
    ) {
      cursor += 1;
    }
  }

  function parseString(): string {
    if (bytes[cursor] !== '"') throw new Error("Expected JSON string");
    cursor += 1;
    let result = "";
    while (cursor < bytes.length) {
      const character = bytes[cursor];
      if (character === '"') {
        cursor += 1;
        return result;
      }
      if (character === "\\") {
        cursor += 1;
        const escaped = bytes[cursor];
        if (escaped === undefined) throw new Error("Unterminated JSON escape");
        cursor += 1;
        switch (escaped) {
          case '"':
          case "\\":
          case "/":
            result += escaped;
            break;
          case "b":
            result += "\b";
            break;
          case "f":
            result += "\f";
            break;
          case "n":
            result += "\n";
            break;
          case "r":
            result += "\r";
            break;
          case "t":
            result += "\t";
            break;
          case "u": {
            const hex = bytes.slice(cursor, cursor + 4);
            if (hex.length !== 4 || !/^[0-9a-fA-F]{4}$/.test(hex)) {
              throw new Error("Invalid JSON unicode escape");
            }
            cursor += 4;
            result += String.fromCharCode(Number.parseInt(hex, 16));
            break;
          }
          default:
            throw new Error("Invalid JSON escape sequence");
        }
        continue;
      }
      if ((character ?? "").charCodeAt(0) < 0x20) {
        throw new Error("Unescaped control character in JSON string");
      }
      result += character;
      cursor += 1;
    }
    throw new Error("Unterminated JSON string");
  }

  function parseNumber(): bigint {
    const start = cursor;
    if (bytes[cursor] === "-") cursor += 1;
    while (cursor < bytes.length && /[0-9]/.test(bytes[cursor] ?? "")) {
      cursor += 1;
    }
    const token = bytes.slice(start, cursor);
    if (token === "" || token === "-") throw new Error("Invalid JSON number");
    if (
      (token.length > 1 && token.startsWith("0")) ||
      (token.startsWith("-0") && token.length > 2)
    ) {
      throw new Error("Invalid JSON number leading zero");
    }
    if (bytes[cursor] === ".") {
      cursor += 1;
      while (cursor < bytes.length && /[0-9]/.test(bytes[cursor] ?? "")) {
        cursor += 1;
      }
    }
    if (bytes[cursor] === "e" || bytes[cursor] === "E") {
      cursor += 1;
      if (bytes[cursor] === "+" || bytes[cursor] === "-") cursor += 1;
      while (cursor < bytes.length && /[0-9]/.test(bytes[cursor] ?? "")) {
        cursor += 1;
      }
    }
    const text = bytes.slice(start, cursor);
    try {
      return BigInt(text.split(/[.eE]/)[0] ?? text);
    } catch {
      throw new Error("Invalid JSON number");
    }
  }

  function parseValue(depth: number): JsonValue {
    if (depth > MAX_JSON_DEPTH) throw new Error("JSON exceeds maximum depth");
    skipWhitespace();
    const character = bytes[cursor];
    if (character === undefined) throw new Error("Unexpected end of JSON");
    if (character === "{") {
      cursor += 1;
      const object: { [key: string]: JsonValue } = {};
      skipWhitespace();
      if (bytes[cursor] === "}") {
        cursor += 1;
        return object;
      }
      for (;;) {
        skipWhitespace();
        const key = parseString();
        if (Object.hasOwn(object, key)) {
          throw new Error(`Duplicate JSON object key: ${key}`);
        }
        skipWhitespace();
        if (bytes[cursor] !== ":") throw new Error("Expected JSON colon");
        cursor += 1;
        object[key] = parseValue(depth + 1);
        skipWhitespace();
        if (bytes[cursor] === ",") {
          cursor += 1;
          continue;
        }
        if (bytes[cursor] === "}") {
          cursor += 1;
          return object;
        }
        throw new Error("Expected JSON comma or closing brace");
      }
    }
    if (character === "[") {
      cursor += 1;
      const array: JsonValue[] = [];
      skipWhitespace();
      if (bytes[cursor] === "]") {
        cursor += 1;
        return array;
      }
      for (;;) {
        array.push(parseValue(depth + 1));
        skipWhitespace();
        if (bytes[cursor] === ",") {
          cursor += 1;
          continue;
        }
        if (bytes[cursor] === "]") {
          cursor += 1;
          return array;
        }
        throw new Error("Expected JSON comma or closing bracket");
      }
    }
    if (character === '"') return parseString();
    if (bytes.startsWith("true", cursor)) {
      cursor += 4;
      return true;
    }
    if (bytes.startsWith("false", cursor)) {
      cursor += 5;
      return false;
    }
    if (bytes.startsWith("null", cursor)) {
      cursor += 4;
      return null;
    }
    return parseNumber();
  }

  const value = parseValue(0);
  skipWhitespace();
  if (cursor !== bytes.length) throw new Error("Trailing JSON content");
  return value;
}

type CompiledScalar = {
  kind:
    | "BOOL"
    | "UINT256_DECIMAL"
    | "UINT256_HEX"
    | "INT256_DECIMAL"
    | "ADDRESS"
    | "BYTES"
    | "BYTES32"
    | "STRING";
  pointer: string;
};

type CompiledTuple = {
  kind: "TUPLE";
  pointer: string;
  children: CompiledNode[];
};

type CompiledArray = {
  kind: "ARRAY";
  pointer: string;
  maxItems: number;
  element: CompiledNode;
};

type CompiledNode = CompiledScalar | CompiledTuple | CompiledArray;

function compileProjection(nodes: readonly JsonAbiNode[]): CompiledNode {
  if (nodes.length === 0) throw new Error("Projection tree is empty");
  if (nodes.length > MAX_NODES)
    throw new Error("Projection exceeds node limit");

  let cursor = 0;
  let valueCount = 0;

  function compile(depth: number): CompiledNode {
    if (depth > MAX_JSON_DEPTH) {
      throw new Error("Projection exceeds maximum depth");
    }
    const source = nodes[cursor];
    if (source === undefined) throw new Error("Incomplete projection tree");
    cursor += 1;

    if (source.nodeType === "TUPLE") {
      if (source.childCount === 0)
        throw new Error("Projection tuple must have children");
      if (source.maxItems !== 0) {
        throw new Error("Projection tuple maxItems must be zero");
      }
      const children: CompiledNode[] = [];
      for (let child = 0; child < source.childCount; child += 1) {
        children.push(compile(depth + 1));
      }
      return { kind: "TUPLE", pointer: source.pointer, children };
    }

    if (source.nodeType === "ARRAY") {
      if (source.childCount !== 1) {
        throw new Error("Projection array must have one element schema");
      }
      if (source.maxItems < 1 || source.maxItems > 256) {
        throw new Error("Invalid projection array limit");
      }
      valueCount += 1;
      const element = compile(depth + 1);
      return {
        kind: "ARRAY",
        pointer: source.pointer,
        maxItems: source.maxItems,
        element,
      };
    }

    if (source.childCount !== 0 || source.maxItems !== 0) {
      throw new Error("Scalar projection node cannot have children");
    }
    valueCount += 1;
    return {
      kind: source.nodeType as CompiledScalar["kind"],
      pointer: source.pointer,
    };
  }

  const root = compile(0);
  if (cursor !== nodes.length)
    throw new Error("Projection contains trailing nodes");
  if (valueCount > MAX_TOTAL_VALUES) {
    throw new Error("Projection exceeds total value limit");
  }
  return root;
}

function resolveJsonPointer(document: JsonValue, pointer: string): JsonValue {
  if (pointer === "") return document;
  if (!pointer.startsWith("/"))
    throw new Error(`Invalid JSON Pointer: ${pointer}`);

  const tokens = pointer
    .slice(1)
    .split("/")
    .map((token) => {
      if (/~(?:[^01]|$)/.test(token))
        throw new Error(`Invalid JSON Pointer escape: ${pointer}`);
      return token.replaceAll("~1", "/").replaceAll("~0", "~");
    });

  let value: JsonValue = document;
  for (const token of tokens) {
    if (Array.isArray(value)) {
      if (!/^(0|[1-9][0-9]*)$/.test(token)) {
        throw new Error(`Invalid JSON array index: ${token}`);
      }
      const index = Number(token);
      if (!Number.isSafeInteger(index) || index >= value.length) {
        throw new Error(`JSON array index does not exist: ${pointer}`);
      }
      const item = value[index];
      if (item === undefined) {
        throw new Error(`JSON array index does not exist: ${pointer}`);
      }
      value = item;
      continue;
    }
    if (
      typeof value !== "object" ||
      value === null ||
      !Object.hasOwn(value, token)
    ) {
      throw new Error(`JSON Pointer does not exist: ${pointer}`);
    }
    const property = value[token];
    if (property === undefined) {
      throw new Error(`JSON Pointer does not exist: ${pointer}`);
    }
    value = property;
  }
  return value;
}

function coerceScalar(node: CompiledScalar, value: JsonValue): unknown {
  switch (node.kind) {
    case "BOOL": {
      if (typeof value !== "boolean") throw new Error("Expected JSON boolean");
      return value;
    }
    case "UINT256_DECIMAL": {
      if (typeof value !== "string" && typeof value !== "bigint") {
        throw new Error("Expected integer or decimal string");
      }
      const text = typeof value === "bigint" ? value.toString() : value;
      if (!/^(0|[1-9][0-9]*)$/.test(text)) {
        throw new Error("Invalid uint256 decimal");
      }
      const parsed = BigInt(text);
      if (parsed < 0n || parsed >= 1n << 256n) {
        throw new Error("uint256 overflow");
      }
      return parsed;
    }
    case "UINT256_HEX": {
      if (typeof value !== "string" || !/^0x[0-9a-fA-F]+$/.test(value)) {
        throw new Error("Invalid hexadecimal uint256");
      }
      const parsed = BigInt(value);
      if (parsed < 0n || parsed >= 1n << 256n) {
        throw new Error("uint256 overflow");
      }
      return parsed;
    }
    case "INT256_DECIMAL": {
      if (typeof value !== "string" && typeof value !== "bigint") {
        throw new Error("Expected integer or decimal string");
      }
      const text = typeof value === "bigint" ? value.toString() : value;
      if (!/^-?(0|[1-9][0-9]*)$/.test(text)) {
        throw new Error("Invalid int256 decimal");
      }
      const parsed = BigInt(text);
      if (parsed < -(1n << 255n) || parsed >= 1n << 255n) {
        throw new Error("int256 overflow");
      }
      return parsed;
    }
    case "ADDRESS": {
      if (typeof value !== "string" || !isAddress(value)) {
        throw new Error("Invalid address");
      }
      return getAddress(value);
    }
    case "BYTES": {
      if (typeof value !== "string" || !/^0x(?:[0-9a-fA-F]{2})*$/.test(value)) {
        throw new Error("Invalid byte string");
      }
      return value;
    }
    case "BYTES32": {
      if (typeof value !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(value)) {
        throw new Error("Invalid bytes32");
      }
      if (size(value as Hex) !== 32) throw new Error("Invalid bytes32 length");
      return value;
    }
    case "STRING": {
      if (typeof value !== "string") throw new Error("Expected JSON string");
      return value;
    }
  }
}

function evaluateProjection(node: CompiledNode, context: JsonValue): unknown {
  const value = resolveJsonPointer(context, node.pointer);

  if (node.kind === "TUPLE") {
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      throw new Error(`Expected JSON object at ${node.pointer}`);
    }
    return node.children.map((child) => evaluateProjection(child, value));
  }

  if (node.kind === "ARRAY") {
    if (!Array.isArray(value)) {
      throw new Error(`Expected JSON array at ${node.pointer}`);
    }
    if (value.length > node.maxItems) {
      throw new Error(`JSON array exceeds maxItems at ${node.pointer}`);
    }
    return value.map((item) => evaluateProjection(node.element, item));
  }

  return coerceScalar(node, value);
}

function projectionAbiParameter(node: CompiledNode): AbiParameter {
  if (node.kind === "TUPLE") {
    return {
      type: "tuple",
      components: node.children.map(projectionAbiParameter),
    };
  }
  if (node.kind === "ARRAY") {
    const element = projectionAbiParameter(node.element);
    return {
      ...element,
      type: `${element.type}[]`,
    } as AbiParameter;
  }
  switch (node.kind) {
    case "BOOL":
      return { type: "bool" };
    case "UINT256_DECIMAL":
    case "UINT256_HEX":
      return { type: "uint256" };
    case "INT256_DECIMAL":
      return { type: "int256" };
    case "ADDRESS":
      return { type: "address" };
    case "BYTES":
      return { type: "bytes" };
    case "BYTES32":
      return { type: "bytes32" };
    case "STRING":
      return { type: "string" };
  }
}

export function transformHttpResponse(parameters: {
  response: HttpResponse;
  transform: ResponseTransform;
}): HttpResponse {
  const rawBodyHash = keccak256(parameters.response.body);

  const result: HttpResponse = {
    ...parameters.response,
    rawBodyHash,
    bodyEncoding: "RAW",
  };

  if (parameters.transform.kind === "RAW") return result;

  if (
    parameters.response.status < parameters.transform.statusFrom ||
    parameters.response.status > parameters.transform.statusTo
  ) {
    return result;
  }

  const document = parseJsonStrict(parameters.response.body);
  const root = compileProjection(parameters.transform.nodes);
  const abiParameter = projectionAbiParameter(root);
  const value = evaluateProjection(root, document);
  const body = encodeAbiParameters(
    [abiParameter] as [AbiParameter],
    [value] as readonly [unknown],
  );

  if (body.length > MAX_PROJECTED_BYTES * 2 + 2) {
    throw new Error("Projected response exceeds client limit");
  }

  return {
    ...result,
    bodyEncoding: "JSON_ABI",
    body,
  };
}

export type { ResponseBodyEncoding };

export { MAX_TOTAL_VALUES, MAX_PROJECTED_BYTES };

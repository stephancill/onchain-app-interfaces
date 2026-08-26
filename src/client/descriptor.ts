import {
  decodeAbiParameters,
  encodeAbiParameters,
  getAddress,
  hexToBytes,
  isAddress,
  isHex,
  type AbiParameter,
  type Hex,
} from "viem";
import { z } from "zod";

const identifierSchema = z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/);
const integerStringSchema = z.string().regex(/^-?[0-9]+$/);
const supportedPatterns = new Set([
  "^[a-z0-9-]+$",
  "^[A-Za-z0-9_-]+$",
  "^[A-Z]{2}$",
]);

export type DescriptorField = {
  name: string;
  abiType: string;
  components?: DescriptorField[] | undefined;
  semanticType?: string | undefined;
  minimum?: string | undefined;
  maximum?: string | undefined;
  minLength?: number | undefined;
  maxLength?: number | undefined;
  minItems?: number | undefined;
  maxItems?: number | undefined;
  pattern?: string | undefined;
  assetField?: string | undefined;
  contentType?: string | undefined;
  sensitivity?: "public" | "private" | "bearer-secret" | undefined;
  enumValues?: Record<string, number> | undefined;
  path?: string | undefined;
  equalsInput?: string | undefined;
};

const descriptorFieldSchema: z.ZodType<DescriptorField> = z.lazy(() =>
  z
    .object({
      name: identifierSchema,
      abiType: z.string().min(1),
      components: z.array(descriptorFieldSchema).optional(),
      semanticType: z.string().min(1).optional(),
      minimum: integerStringSchema.optional(),
      maximum: integerStringSchema.optional(),
      minLength: z.number().int().nonnegative().optional(),
      maxLength: z.number().int().nonnegative().optional(),
      minItems: z.number().int().nonnegative().optional(),
      maxItems: z.number().int().nonnegative().optional(),
      pattern: z.string().min(1).optional(),
      assetField: z.string().min(1).optional(),
      contentType: z.string().min(1).optional(),
      sensitivity: z.enum(["public", "private", "bearer-secret"]).optional(),
      enumValues: z
        .record(z.string(), z.number().int().nonnegative())
        .optional(),
      path: z.string().min(1).optional(),
      equalsInput: identifierSchema.optional(),
    })
    .strict()
    .superRefine((field, context) => {
      const isTuple = field.abiType === "tuple" || field.abiType === "tuple[]";
      const isArray = field.abiType.endsWith("[]");
      if (isTuple && field.components === undefined) {
        context.addIssue({
          code: "custom",
          message: "Tuple fields require components",
        });
      }
      if (!isTuple && field.components !== undefined) {
        context.addIssue({
          code: "custom",
          message: "Only tuple fields may have components",
        });
      }
      if (field.components !== undefined) {
        const names = new Set<string>();
        for (const component of field.components) {
          if (names.has(component.name)) {
            context.addIssue({
              code: "custom",
              message: `Duplicate field: ${component.name}`,
            });
          }
          names.add(component.name);
        }
      }
      if (
        field.minimum !== undefined &&
        field.maximum !== undefined &&
        BigInt(field.minimum) > BigInt(field.maximum)
      ) {
        context.addIssue({
          code: "custom",
          message: "minimum exceeds maximum",
        });
      }
      if (
        field.minLength !== undefined &&
        field.maxLength !== undefined &&
        field.minLength > field.maxLength
      ) {
        context.addIssue({
          code: "custom",
          message: "minLength exceeds maxLength",
        });
      }
      if (
        !isArray &&
        (field.minItems !== undefined || field.maxItems !== undefined)
      ) {
        context.addIssue({
          code: "custom",
          message: "Only array fields may have item constraints",
        });
      }
      if (
        field.minItems !== undefined &&
        field.maxItems !== undefined &&
        field.minItems > field.maxItems
      ) {
        context.addIssue({
          code: "custom",
          message: "minItems exceeds maxItems",
        });
      }
      if (
        field.pattern !== undefined &&
        !supportedPatterns.has(field.pattern)
      ) {
        context.addIssue({
          code: "custom",
          message: "Unsupported string pattern",
        });
      }
      const pathMarkers = validatePathSyntax(field, context);
      if (isArray && pathMarkers !== 1) {
        context.addIssue({
          code: "custom",
          message: `Array field ${field.name} requires exactly one [] path segment`,
        });
      }
      if (!isArray && pathMarkers !== 0) {
        context.addIssue({
          code: "custom",
          message: `Non-array field ${field.name} must not use [] path segments`,
        });
      }
    }),
);

const pathSegmentSchema = /^[A-Za-z_][A-Za-z0-9_-]*(\[\])?$/;

function validatePathSyntax(
  field: DescriptorField,
  context: z.RefinementCtx,
): number {
  if (field.path === undefined) return field.abiType.endsWith("[]") ? 1 : 0;
  let markers = 0;
  const segments = field.path.split(".");
  for (const segment of segments) {
    if (!pathSegmentSchema.test(segment)) {
      context.addIssue({
        code: "custom",
        message: `Invalid JSON path segment: ${segment}`,
      });
      return Number.NaN;
    }
    if (segment.endsWith("[]")) markers++;
  }
  if (markers > 1) {
    context.addIssue({
      code: "custom",
      message: `Field ${field.name} has more than one [] path segment`,
    });
    return Number.NaN;
  }
  return markers;
}

const fieldsSchema = z
  .array(descriptorFieldSchema)
  .superRefine((fields, context) => {
    const names = new Set<string>();
    for (const field of fields) {
      if (names.has(field.name)) {
        context.addIssue({
          code: "custom",
          message: `Duplicate field: ${field.name}`,
        });
      }
      names.add(field.name);
    }
  });

const effectSchema = z
  .object({
    type: z.enum(["increase", "decrease", "set", "external"]),
    assetField: z.string().optional(),
    amountField: z.string().optional(),
    minimumField: z.string().optional(),
    description: z.string().optional(),
  })
  .strict();

const baseDescriptorSchema = z.object({
  version: z.literal("0.1"),
  name: z.string().min(1),
  description: z.string().optional(),
  inputs: z
    .object({ encoding: z.literal("abi"), fields: fieldsSchema })
    .strict(),
  provenance: z
    .object({ type: z.enum(["onchain", "configured-origin", "hybrid"]) })
    .strict()
    .optional(),
});

const abiOutputSchema = z
  .object({ encoding: z.literal("abi"), fields: fieldsSchema })
  .strict();

const jsonOutputSchema = z
  .object({
    encoding: z.literal("json"),
    fields: fieldsSchema,
    mediaType: z.string().min(1).optional(),
  })
  .strict();

const queryDescriptorSchema = baseDescriptorSchema
  .extend({
    kind: z.literal("query"),
    output: z.discriminatedUnion("encoding", [
      abiOutputSchema,
      jsonOutputSchema,
    ]),
  })
  .strict();

const actionDescriptorSchema = baseDescriptorSchema
  .extend({
    kind: z.literal("action"),
    output: z.object({ encoding: z.literal("preparedAction") }).strict(),
    effects: z.array(effectSchema).optional(),
    execution: z
      .object({ atomicity: z.enum(["sequential-allowed", "atomic-required"]) })
      .strict()
      .optional(),
  })
  .strict();

export const applicationDescriptorSchema = z.discriminatedUnion("kind", [
  queryDescriptorSchema,
  actionDescriptorSchema,
]);

export type ApplicationDescriptor = z.infer<typeof applicationDescriptorSchema>;
export type QueryDescriptor = z.infer<typeof queryDescriptorSchema>;
export type ActionDescriptor = z.infer<typeof actionDescriptorSchema>;

const supportedAbiType =
  /^(address|bool|string|bytes|bytes(?:[1-9]|[12][0-9]|3[0-2])|u?int(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)?)$/;

function validateAbiTypes(fields: readonly DescriptorField[]): void {
  for (const field of fields) {
    if (field.abiType === "tuple" || field.abiType === "tuple[]") {
      validateAbiTypes(field.components ?? []);
    } else {
      const elementType = field.abiType.endsWith("[]")
        ? field.abiType.slice(0, -2)
        : field.abiType;
      if (!supportedAbiType.test(elementType)) {
        throw new Error(`Unsupported descriptor ABI type: ${field.abiType}`);
      }
    }
    if (field.abiType.endsWith("[][]")) {
      throw new Error(`Unsupported descriptor ABI type: ${field.abiType}`);
    }
  }
}

export function parseApplicationDescriptor(
  value: Uint8Array | Hex | string,
): ApplicationDescriptor {
  let json: string;
  if (value instanceof Uint8Array) json = new TextDecoder().decode(value);
  else if (typeof value === "string" && value.startsWith("0x")) {
    json = new TextDecoder().decode(hexToBytes(value as Hex));
  } else json = value as string;

  const descriptor = applicationDescriptorSchema.parse(JSON.parse(json));
  validateAbiTypes(descriptor.inputs.fields);
  if (descriptor.kind === "query") {
    validateAbiTypes(descriptor.output.fields);
    validateJsonOutputBindings(descriptor);
  }
  return descriptor;
}

function isJsonOutput(
  output: QueryDescriptor["output"],
): output is Extract<QueryDescriptor["output"], { encoding: "json" }> {
  return output.encoding === "json";
}

function validateJsonOutputBindings(descriptor: QueryDescriptor): void {
  const inputNames = new Set(
    descriptor.inputs.fields.map((field) => field.name),
  );
  const jsonOutput = isJsonOutput(descriptor.output);
  const visit = (field: DescriptorField) => {
    if (
      !jsonOutput &&
      (field.path !== undefined || field.equalsInput !== undefined)
    ) {
      throw new Error(
        `Field ${field.name} uses JSON-only properties in a non-JSON output`,
      );
    }
    if (field.equalsInput !== undefined && !inputNames.has(field.equalsInput)) {
      throw new Error(
        `Field ${field.name} binds to unknown input ${field.equalsInput}`,
      );
    }
    if (field.equalsInput !== undefined && field.abiType.endsWith("[]")) {
      throw new Error(`Array field ${field.name} must not use equalsInput`);
    }
    for (const component of field.components ?? []) visit(component);
  };
  for (const field of descriptor.output.fields) visit(field);
}

function abiParameter(field: DescriptorField): AbiParameter {
  if (field.abiType === "tuple" || field.abiType === "tuple[]") {
    return {
      name: field.name,
      type: field.abiType,
      components: (field.components ?? []).map(abiParameter),
    };
  }
  return { name: field.name, type: field.abiType } as AbiParameter;
}

function integerValue(field: DescriptorField, value: unknown): bigint {
  let parsed: bigint;
  if (typeof value === "bigint") parsed = value;
  else if (typeof value === "number" && Number.isSafeInteger(value))
    parsed = BigInt(value);
  else if (
    typeof value === "string" &&
    integerStringSchema.safeParse(value).success
  ) {
    const enumValue = field.enumValues?.[value];
    parsed = enumValue === undefined ? BigInt(value) : BigInt(enumValue);
  } else if (
    typeof value === "string" &&
    field.enumValues?.[value] !== undefined
  ) {
    parsed = BigInt(field.enumValues[value]);
  } else throw new Error(`Invalid integer value for ${field.name}`);

  if (field.minimum !== undefined && parsed < BigInt(field.minimum)) {
    throw new Error(`${field.name} is below its minimum`);
  }
  if (field.maximum !== undefined && parsed > BigInt(field.maximum)) {
    throw new Error(`${field.name} exceeds its maximum`);
  }
  return parsed;
}

function normalizeValue(field: DescriptorField, value: unknown): unknown {
  if (field.abiType.endsWith("[]")) {
    if (!Array.isArray(value)) {
      throw new Error(`Invalid array value for ${field.name}`);
    }
    if (field.minItems !== undefined && value.length < field.minItems) {
      throw new Error(`${field.name} has fewer than its minimum items`);
    }
    if (field.maxItems !== undefined && value.length > field.maxItems) {
      throw new Error(`${field.name} exceeds its maximum items`);
    }
    const elementField = {
      ...field,
      abiType: field.abiType.slice(0, -2),
      minItems: undefined,
      maxItems: undefined,
    };
    return value.map((item) => normalizeValue(elementField, item));
  }
  if (field.abiType === "tuple") {
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      throw new Error(`Invalid tuple value for ${field.name}`);
    }
    const record = value as Record<string, unknown>;
    return Object.fromEntries(
      (field.components ?? []).map((component) => [
        component.name,
        normalizeValue(component, record[component.name]),
      ]),
    );
  }
  if (/^u?int/.test(field.abiType)) return integerValue(field, value);
  if (field.abiType === "address") {
    if (typeof value !== "string" || !isAddress(value)) {
      throw new Error(`Invalid address value for ${field.name}`);
    }
    return getAddress(value);
  }
  if (field.abiType === "bool") {
    if (typeof value !== "boolean")
      throw new Error(`Invalid boolean value for ${field.name}`);
    return value;
  }
  if (field.abiType === "string") {
    if (typeof value !== "string")
      throw new Error(`Invalid string value for ${field.name}`);
    if (field.minLength !== undefined && value.length < field.minLength) {
      throw new Error(`${field.name} is shorter than its minimum length`);
    }
    if (field.maxLength !== undefined && value.length > field.maxLength) {
      throw new Error(`${field.name} exceeds its maximum length`);
    }
    if (field.pattern !== undefined && !new RegExp(field.pattern).test(value)) {
      throw new Error(`${field.name} does not match its required pattern`);
    }
    return value;
  }
  if (field.abiType.startsWith("bytes")) {
    if (typeof value !== "string" || !isHex(value)) {
      throw new Error(`Invalid bytes value for ${field.name}`);
    }
    return value;
  }
  throw new Error(`Unsupported descriptor ABI type: ${field.abiType}`);
}

export function encodeDescriptorParameters(parameters: {
  descriptor: ApplicationDescriptor;
  values: Record<string, unknown>;
}): Hex {
  const fields = parameters.descriptor.inputs.fields;
  return encodeAbiParameters(
    fields.map(abiParameter),
    fields.map((field) =>
      normalizeValue(field, parameters.values[field.name]),
    ) as readonly unknown[],
  );
}

function namedDecodedValue(field: DescriptorField, value: unknown): unknown {
  if (field.abiType.endsWith("[]")) {
    if (!Array.isArray(value)) {
      throw new Error(`Invalid decoded array value for ${field.name}`);
    }
    if (field.minItems !== undefined && value.length < field.minItems) {
      throw new Error(`${field.name} has fewer than its minimum items`);
    }
    if (field.maxItems !== undefined && value.length > field.maxItems) {
      throw new Error(`${field.name} exceeds its maximum items`);
    }
    const elementField = { ...field, abiType: field.abiType.slice(0, -2) };
    return value.map((item) => namedDecodedValue(elementField, item));
  }
  if (field.abiType !== "tuple") return value;
  if (typeof value !== "object" || value === null) {
    throw new Error(`Invalid decoded tuple value for ${field.name}`);
  }
  const components = field.components ?? [];
  const record = value as Record<string, unknown> & readonly unknown[];
  return Object.fromEntries(
    components.map((component, index) => [
      component.name,
      namedDecodedValue(component, record[component.name] ?? record[index]),
    ]),
  );
}

export function decodeDescriptorResult(parameters: {
  descriptor: QueryDescriptor;
  data: Hex;
  inputValues?: Record<string, unknown> | undefined;
}): Record<string, unknown> {
  const fields = parameters.descriptor.output.fields;
  if (parameters.descriptor.output.encoding === "json") {
    return decodeJsonResult({
      fields,
      data: parameters.data,
      inputValues: parameters.inputValues,
    });
  }
  if (!parameters.descriptor.output.encoding.startsWith("abi")) {
    throw new Error(
      `Unsupported output encoding: ${parameters.descriptor.output.encoding}`,
    );
  }
  const decoded = decodeAbiParameters(
    fields.map(abiParameter),
    parameters.data,
  );
  return Object.fromEntries(
    fields.map((field, index) => [
      field.name,
      namedDecodedValue(field, decoded[index]),
    ]),
  );
}

function requireInputValues(
  fields: readonly DescriptorField[],
  inputValues: Record<string, unknown> | undefined,
): Record<string, unknown> {
  const requiresBindings = fields.some((field) =>
    jsonFieldTree(field).some((leaf) => leaf.equalsInput !== undefined),
  );
  if (requiresBindings && inputValues === undefined) {
    throw new Error("Descriptor result requires input values for equalsInput");
  }
  return inputValues ?? {};
}

function jsonFieldTree(field: DescriptorField): readonly DescriptorField[] {
  return [field, ...(field.components ?? []).flatMap(jsonFieldTree)];
}

function resolvePath(node: unknown, path: string): unknown {
  let current = node;
  for (const segment of path.split(".")) {
    if (
      typeof current !== "object" ||
      current === null ||
      Array.isArray(current)
    ) {
      throw new Error(`JSON path ${path} traverses a non-object`);
    }
    const value = (current as Record<string, unknown>)[segment];
    if (value === undefined) {
      throw new Error(`JSON path ${path} is missing key ${segment}`);
    }
    current = value;
  }
  return current;
}

function selectionPath(field: DescriptorField): string {
  const path = field.path ?? field.name;
  return path.endsWith("[]") ? path.slice(0, -2) : path;
}

function assertBoundValue(
  field: DescriptorField,
  value: unknown,
  expected: unknown,
): void {
  if (field.abiType === "address") {
    if (
      typeof value !== "string" ||
      typeof expected !== "string" ||
      getAddress(value).toLowerCase() !== getAddress(expected).toLowerCase()
    ) {
      throw new Error(`${field.name} does not match its bound input value`);
    }
    return;
  }
  if (/^u?int/.test(field.abiType)) {
    if (
      typeof value === "bigint" &&
      BigInt(expected as string | number) !== value
    ) {
      throw new Error(`${field.name} does not match its bound input value`);
    }
    return;
  }
  if (value !== expected) {
    throw new Error(`${field.name} does not match its bound input value`);
  }
}

function extractJsonValue(
  field: DescriptorField,
  node: unknown,
  inputValues: Record<string, unknown>,
): unknown {
  return extractResolvedValue(
    field,
    resolvePath(node, selectionPath(field)),
    inputValues,
  );
}

function extractResolvedValue(
  field: DescriptorField,
  value: unknown,
  inputValues: Record<string, unknown>,
): unknown {
  if (field.abiType.endsWith("[]")) {
    if (!Array.isArray(value)) {
      throw new Error(`Invalid array value for ${field.name}`);
    }
    if (field.minItems !== undefined && value.length < field.minItems) {
      throw new Error(`${field.name} has fewer than its minimum items`);
    }
    if (field.maxItems !== undefined && value.length > field.maxItems) {
      throw new Error(`${field.name} exceeds its maximum items`);
    }
    const elementField = {
      ...field,
      abiType: field.abiType.slice(0, -2),
      minItems: undefined,
      maxItems: undefined,
      path: undefined,
    };
    return value.map((element) =>
      extractResolvedValue(elementField, element, inputValues),
    );
  }
  if (field.abiType === "tuple") {
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      throw new Error(`Invalid tuple value for ${field.name}`);
    }
    return Object.fromEntries(
      (field.components ?? []).map((component) => [
        component.name,
        extractJsonValue(component, value, inputValues),
      ]),
    );
  }
  const normalized = normalizeValue(field, value);
  if (field.equalsInput !== undefined) {
    assertBoundValue(field, normalized, inputValues[field.equalsInput]);
  }
  return normalized;
}

function decodeJsonResult(parameters: {
  fields: readonly DescriptorField[];
  data: Hex;
  inputValues?: Record<string, unknown> | undefined;
}): Record<string, unknown> {
  const inputValues = requireInputValues(
    parameters.fields,
    parameters.inputValues,
  );
  const body: unknown = JSON.parse(
    new TextDecoder().decode(hexToBytes(parameters.data)),
  );
  return Object.fromEntries(
    parameters.fields.map((field) => [
      field.name,
      extractJsonValue(field, body, inputValues),
    ]),
  );
}

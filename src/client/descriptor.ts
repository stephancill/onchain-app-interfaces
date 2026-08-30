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
  pattern?: string | undefined;
  assetField?: string | undefined;
  contentType?: string | undefined;
  sensitivity?: "public" | "private" | "bearer-secret" | undefined;
  enumValues?: Record<string, number> | undefined;
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
      pattern: z.string().min(1).optional(),
      assetField: z.string().min(1).optional(),
      contentType: z.string().min(1).optional(),
      sensitivity: z.enum(["public", "private", "bearer-secret"]).optional(),
      enumValues: z
        .record(z.string(), z.number().int().nonnegative())
        .optional(),
    })
    .strict()
    .superRefine((field, context) => {
      const core = field.abiType.split("[]")[0] ?? field.abiType;
      const isTuple = core === "tuple";
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
        field.pattern !== undefined &&
        !supportedPatterns.has(field.pattern)
      ) {
        context.addIssue({
          code: "custom",
          message: "Unsupported string pattern",
        });
      }
    }),
);

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
    chainIdField: z.string().optional(),
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

const queryDescriptorSchema = baseDescriptorSchema
  .extend({
    kind: z.literal("query"),
    output: z
      .object({ encoding: z.literal("abi"), fields: fieldsSchema })
      .strict(),
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
  /^(address|bool|string|bytes|bytes(?:[1-9]|[12][0-9]|3[0-2])|u?int(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)?)(\[\])*$/;

function coreAbiType(field: DescriptorField): string {
  const first = field.abiType.split("[]")[0];
  return first === undefined ? field.abiType : first;
}

function validateAbiTypes(fields: readonly DescriptorField[]): void {
  for (const field of fields) {
    if (coreAbiType(field) === "tuple") {
      validateAbiTypes(field.components ?? []);
    } else if (!supportedAbiType.test(field.abiType)) {
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
  if (descriptor.kind === "query") validateAbiTypes(descriptor.output.fields);
  return descriptor;
}

function abiParameter(field: DescriptorField): AbiParameter {
  const core = coreAbiType(field);
  const arraySuffix = field.abiType.slice(core.length);
  if (core === "tuple") {
    return {
      name: field.name,
      type: `tuple${arraySuffix}`,
      components: (field.components ?? []).map(abiParameter),
    } as AbiParameter;
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
  const core = coreAbiType(field);
  const arraySuffix = field.abiType.slice(core.length);

  if (core === "tuple") {
    const components = field.components ?? [];
    const normalizeTuple = (candidate: unknown): unknown => {
      if (
        typeof candidate !== "object" ||
        candidate === null ||
        Array.isArray(candidate)
      ) {
        throw new Error(`Invalid tuple value for ${field.name}`);
      }
      const record = candidate as Record<string, unknown>;
      return Object.fromEntries(
        components.map((component) => [
          component.name,
          normalizeValue(component, record[component.name]),
        ]),
      );
    };
    if (arraySuffix === "") return normalizeTuple(value);
    if (arraySuffix === "[]" && Array.isArray(value)) {
      return value.map(normalizeTuple);
    }
    throw new Error(`Unsupported tuple array shape for ${field.name}`);
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

function decodeJsonBytes(value: Hex): unknown {
  const text = new TextDecoder().decode(hexToBytes(value));
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function namedDecodedValue(field: DescriptorField, value: unknown): unknown {
  const core = coreAbiType(field);
  const arraySuffix = field.abiType.slice(core.length);
  if (
    core === "bytes" &&
    field.contentType === "application/json" &&
    field.sensitivity !== "bearer-secret" &&
    typeof value === "string" &&
    isHex(value)
  ) {
    return decodeJsonBytes(value);
  }
  if (core !== "tuple") return value;
  const components = field.components ?? [];
  const nameTuple = (candidate: unknown): unknown => {
    const record = candidate as Record<string, unknown> & readonly unknown[];
    return Object.fromEntries(
      components.map((component, index) => [
        component.name,
        namedDecodedValue(component, record[component.name] ?? record[index]),
      ]),
    );
  };
  if (arraySuffix === "") return nameTuple(value);
  if (arraySuffix === "[]" && Array.isArray(value)) return value.map(nameTuple);
  return value;
}

export function decodeDescriptorResult(parameters: {
  descriptor: QueryDescriptor;
  data: Hex;
}): Record<string, unknown> {
  const fields = parameters.descriptor.output.fields;
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

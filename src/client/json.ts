export function stringifyJson(value: unknown, space = 2): string {
  return JSON.stringify(
    value,
    (_, item: unknown) => (typeof item === "bigint" ? item.toString() : item),
    space,
  );
}

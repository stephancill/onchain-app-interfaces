# Low-Level Decoding

Use this only when diagnosing the bundled Python client or integrating the TypeScript library directly.

## Single Outputs

Viem's `decodeFunctionResult` returns the output value itself when a function has one output. Do not destructure it as an output array:

```typescript
const descriptorBytes = decodeFunctionResult({
  abi: applicationQueriesAbi,
  functionName: "queryDescriptor",
  data,
});
```

The same rule applies to the outer `bytes` returned by `query`. Decode that function result first, then pass the resulting bytes to `decodeDescriptorResult`.

## PreparedAction

`prepare` has one output: a nested `PreparedAction` tuple. Its shape is:

```text
((address target,uint256 value,bytes data)[] calls,uint256 validUntil)
```

Do not flatten the tuple. Dynamic offsets are relative to their enclosing ABI container. When decoding raw function return bytes there is no selector to remove. When diagnosing calldata, remove exactly four bytes: eight hex characters from an already unprefixed payload, or ten total string characters when the value still begins with `0x`. Prefer ABI function decoders over manual slicing.

Use BigInt-aware JSON output such as the exported `stringifyJson` helper. Native `JSON.stringify` throws on `bigint`.

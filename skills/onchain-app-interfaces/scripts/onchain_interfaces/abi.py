"""Small, strict Ethereum ABI coder with no third-party dependencies."""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any, Optional, Union

from .keccak import function_selector, to_checksum_address

_WORD_SIZE = 32
_IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$", re.ASCII)
_TYPE_NAME_RE = re.compile(r"[A-Za-z][A-Za-z0-9]*", re.ASCII)
_HEX_RE = re.compile(r"^[0-9a-fA-F]*$", re.ASCII)


class ABIError(ValueError):
    """Base class for ABI syntax, value, and data errors."""


class ABITypeError(ABIError):
    """Raised for unsupported or malformed ABI type declarations."""


class ABIEncodingError(ABIError):
    """Raised when a Python value cannot be encoded as its ABI type."""


class ABIDecodingError(ABIError):
    """Raised when ABI bytes are malformed or non-canonical."""


@dataclass(frozen=True)
class ABIType:
    """Recursive ABI type model."""

    kind: str
    bits: int | None = None
    size: int | None = None
    components: tuple["ABIParameter", ...] = ()
    item_type: Optional["ABIType"] = None

    @property
    def canonical_type(self) -> str:
        if self.kind in ("uint", "int"):
            return "%s%d" % (self.kind, self.bits)
        if self.kind == "fixed_bytes":
            return "bytes%d" % self.size
        if self.kind == "tuple":
            return (
                "("
                + ",".join(
                    component.type.canonical_type for component in self.components
                )
                + ")"
            )
        if self.kind == "array":
            if self.item_type is None:
                raise ABITypeError("array type has no item type")
            return self.item_type.canonical_type + "[]"
        return self.kind

    @property
    def is_dynamic(self) -> bool:
        if self.kind in ("string", "bytes", "array"):
            return True
        if self.kind == "tuple":
            return any(component.type.is_dynamic for component in self.components)
        return False

    @property
    def static_size(self) -> int:
        if self.is_dynamic:
            raise ABITypeError("dynamic ABI types do not have an inline static size")
        if self.kind == "tuple":
            return sum(component.type.static_size for component in self.components)
        return _WORD_SIZE

    def __str__(self) -> str:
        return self.canonical_type


@dataclass(frozen=True)
class ABIParameter:
    """A named or unnamed ABI parameter."""

    type: ABIType
    name: str = ""

    @property
    def canonical_type(self) -> str:
        return self.type.canonical_type


TypeInput = Union[str, ABIType, ABIParameter, Mapping[str, Any]]
ParameterInput = Union[str, ABIType, ABIParameter, Mapping[str, Any]]


class _TypeParser:
    def __init__(self, text: str):
        self.text = text
        self.position = 0

    def _skip_space(self) -> None:
        while self.position < len(self.text) and self.text[self.position].isspace():
            self.position += 1

    def _consume(self, token: str) -> bool:
        self._skip_space()
        if self.text.startswith(token, self.position):
            self.position += len(token)
            return True
        return False

    def _identifier(self) -> str | None:
        self._skip_space()
        match = _TYPE_NAME_RE.match(self.text, self.position)
        if match is None:
            return None
        self.position = match.end()
        return match.group(0)

    def parse_type(self) -> ABIType:
        self._skip_space()
        if self._consume("("):
            components: list[ABIParameter] = []
            if not self._consume(")"):
                while True:
                    components.append(self.parse_parameter())
                    if self._consume(")"):
                        break
                    if not self._consume(","):
                        raise ABITypeError(
                            "expected ',' or ')' at position %d" % self.position
                        )
            _validate_component_names(components)
            value = ABIType(kind="tuple", components=tuple(components))
        else:
            type_name = self._identifier()
            if type_name is None:
                raise ABITypeError("expected ABI type at position %d" % self.position)
            value = _primitive_type(type_name)

        while self._consume("["):
            if not self._consume("]"):
                raise ABITypeError("only dynamic arrays with [] are supported")
            value = ABIType(kind="array", item_type=value)
        return value

    def parse_parameter(self) -> ABIParameter:
        value_type = self.parse_type()
        self._skip_space()
        start = self.position
        name = self._identifier() or ""
        if name and not _IDENTIFIER_RE.fullmatch(name):
            raise ABITypeError("invalid parameter name: %s" % name)
        if not name:
            self.position = start
        return ABIParameter(type=value_type, name=name)

    def parse_parameters(self) -> tuple[ABIParameter, ...]:
        parameters: list[ABIParameter] = []
        self._skip_space()
        if self.position == len(self.text):
            return ()
        while True:
            parameters.append(self.parse_parameter())
            self._skip_space()
            if self.position == len(self.text):
                return tuple(parameters)
            if not self._consume(","):
                raise ABITypeError("expected ',' at position %d" % self.position)

    def require_end(self) -> None:
        self._skip_space()
        if self.position != len(self.text):
            raise ABITypeError("unexpected input at position %d" % self.position)


def _primitive_type(type_name: str) -> ABIType:
    if type_name == "uint" or type_name == "int":
        return ABIType(kind=type_name, bits=256)
    if type_name.startswith("uint") or type_name.startswith("int"):
        kind = "uint" if type_name.startswith("uint") else "int"
        suffix = type_name[len(kind) :]
        if suffix.isdigit():
            bits = int(suffix)
            if 8 <= bits <= 256 and bits % 8 == 0:
                return ABIType(kind=kind, bits=bits)
        raise ABITypeError("invalid integer ABI type: %s" % type_name)
    if type_name == "bytes":
        return ABIType(kind="bytes")
    if type_name.startswith("bytes"):
        suffix = type_name[5:]
        if suffix.isdigit() and 1 <= int(suffix) <= 32:
            return ABIType(kind="fixed_bytes", size=int(suffix))
        raise ABITypeError("invalid fixed-bytes ABI type: %s" % type_name)
    if type_name in ("address", "bool", "string"):
        return ABIType(kind=type_name)
    if type_name == "tuple":
        raise ABITypeError("tuple declarations require components")
    raise ABITypeError("unsupported ABI type: %s" % type_name)


def _validate_component_names(components: Sequence[ABIParameter]) -> None:
    names = set()
    for component in components:
        if component.name:
            if component.name in names:
                raise ABITypeError(
                    "duplicate tuple component name: %s" % component.name
                )
            names.add(component.name)


def parse_abi_type(
    value: TypeInput, *, components: Sequence[ParameterInput] | None = None
) -> ABIType:
    """Parse one ABI type, including recursive tuples and dynamic arrays.

    ``components`` is used with descriptor/JSON ABI declarations such as
    ``value="tuple[]"``. Canonical tuple strings such as
    ``"(address,uint256[])[]"`` carry their components inline.
    """

    if isinstance(value, ABIParameter):
        if components is not None:
            raise ABITypeError("components cannot override an ABIParameter")
        return value.type
    if isinstance(value, ABIType):
        if components is not None:
            raise ABITypeError("components cannot override an ABIType")
        return value
    if isinstance(value, Mapping):
        if components is not None:
            raise ABITypeError("components cannot override a parameter mapping")
        return parse_abi_parameter(value).type
    if not isinstance(value, str):
        raise TypeError("ABI type must be a string, ABIType, ABIParameter, or mapping")

    if components is None:
        parser = _TypeParser(value)
        parsed = parser.parse_type()
        parser.require_end()
        return parsed

    match = re.fullmatch(r"tuple((?:\[\])*)", value.strip())
    if match is None:
        raise ABITypeError(
            "components may only accompany tuple or tuple[] declarations"
        )
    parsed_components = tuple(
        parse_abi_parameter(component) for component in components
    )
    _validate_component_names(parsed_components)
    parsed = ABIType(kind="tuple", components=parsed_components)
    for _ in range(len(match.group(1)) // 2):
        parsed = ABIType(kind="array", item_type=parsed)
    return parsed


def parse_abi_parameter(value: ParameterInput) -> ABIParameter:
    """Parse a parameter string or a JSON/descriptor-style parameter mapping."""

    if isinstance(value, ABIParameter):
        return value
    if isinstance(value, ABIType):
        return ABIParameter(type=value)
    if isinstance(value, str):
        parser = _TypeParser(value)
        parsed = parser.parse_parameter()
        parser.require_end()
        return parsed
    if not isinstance(value, Mapping):
        raise TypeError(
            "ABI parameter must be a string, ABIType, ABIParameter, or mapping"
        )

    unknown = set(value) - {"name", "type", "abiType", "components"}
    if unknown:
        raise ABITypeError(
            "unknown ABI parameter keys: %s"
            % ", ".join(sorted(str(item) for item in unknown))
        )
    if "type" in value and "abiType" in value:
        raise ABITypeError("parameter cannot declare both type and abiType")
    type_value = value.get("type", value.get("abiType"))
    if not isinstance(type_value, str):
        raise ABITypeError("parameter mapping requires a string type or abiType")
    name = value.get("name", "")
    if not isinstance(name, str) or (name and not _IDENTIFIER_RE.fullmatch(name)):
        raise ABITypeError("invalid ABI parameter name")
    component_values = value.get("components")
    if component_values is not None and (
        isinstance(component_values, (str, bytes, bytearray))
        or not isinstance(component_values, Sequence)
    ):
        raise ABITypeError("components must be a sequence")
    parsed_type = parse_abi_type(type_value, components=component_values)
    if component_values is None and _base_kind(parsed_type) == "tuple":
        raise ABITypeError("tuple parameter mappings require components")
    return ABIParameter(type=parsed_type, name=name)


def parse_abi_parameters(
    values: str | Sequence[ParameterInput],
) -> tuple[ABIParameter, ...]:
    """Parse a comma-separated parameter list or parameter sequence."""

    if isinstance(values, str):
        return _TypeParser(values).parse_parameters()
    if isinstance(values, (bytes, bytearray)) or not isinstance(values, Sequence):
        raise TypeError("parameters must be a string or sequence")
    parsed = tuple(parse_abi_parameter(value) for value in values)
    _validate_component_names(parsed)
    return parsed


def _base_kind(value_type: ABIType) -> str:
    current = value_type
    while current.kind == "array":
        if current.item_type is None:
            raise ABITypeError("array type has no item type")
        current = current.item_type
    return current.kind


def canonical_signature(
    *, name: str, parameters: str | Sequence[ParameterInput]
) -> str:
    """Build a canonical function/error signature from parameter declarations."""

    if not isinstance(name, str) or not _IDENTIFIER_RE.fullmatch(name):
        raise ABITypeError("invalid function or error name")
    parsed = parse_abi_parameters(parameters)
    return (
        name
        + "("
        + ",".join(parameter.type.canonical_type for parameter in parsed)
        + ")"
    )


def selector(*, name: str, parameters: str | Sequence[ParameterInput]) -> bytes:
    """Build and hash a canonical function/error signature."""

    return function_selector(canonical_signature(name=name, parameters=parameters))


def _word(value: int) -> bytes:
    return value.to_bytes(_WORD_SIZE, "big")


def _padded_size(length: int) -> int:
    return ((length + _WORD_SIZE - 1) // _WORD_SIZE) * _WORD_SIZE


def _bytes_value(value: Any, *, context: str) -> bytes:
    if isinstance(value, (bytes, bytearray, memoryview)):
        return bytes(value)
    if isinstance(value, str) and value.startswith("0x"):
        digits = value[2:]
        if len(digits) % 2 == 0 and _HEX_RE.fullmatch(digits):
            return bytes.fromhex(digits)
    raise ABIEncodingError(
        "%s must be bytes-like or an even-length 0x hex string" % context
    )


def _tuple_values(components: Sequence[ABIParameter], value: Any) -> tuple[Any, ...]:
    if isinstance(value, Mapping):
        if any(not component.name for component in components):
            raise ABIEncodingError(
                "mapping tuple values require every component to be named"
            )
        expected = {component.name for component in components}
        actual = set(value)
        if actual != expected:
            missing = expected - actual
            extra = actual - expected
            details = []
            if missing:
                details.append("missing " + ", ".join(sorted(missing)))
            if extra:
                details.append(
                    "unexpected " + ", ".join(sorted(str(item) for item in extra))
                )
            raise ABIEncodingError(
                "tuple mapping keys do not match components (%s)" % "; ".join(details)
            )
        return tuple(value[component.name] for component in components)
    if isinstance(value, Sequence) and not isinstance(
        value, (str, bytes, bytearray, memoryview)
    ):
        if len(value) != len(components):
            raise ABIEncodingError(
                "tuple has %d values; expected %d" % (len(value), len(components))
            )
        return tuple(value)
    raise ABIEncodingError("tuple value must be a mapping or non-string sequence")


def _encode_container(types: Sequence[ABIType], values: Sequence[Any]) -> bytes:
    if len(types) != len(values):
        raise ABIEncodingError(
            "received %d values for %d ABI parameters" % (len(values), len(types))
        )
    head_size = sum(
        _WORD_SIZE if value_type.is_dynamic else value_type.static_size
        for value_type in types
    )
    heads: list[bytes] = []
    tails: list[bytes] = []
    tail_size = 0
    for value_type, value in zip(types, values):
        if value_type.is_dynamic:
            encoded = _encode_value(value_type, value)
            heads.append(_word(head_size + tail_size))
            tails.append(encoded)
            tail_size += len(encoded)
        else:
            heads.append(_encode_value(value_type, value))
    return b"".join(heads + tails)


def _encode_value(value_type: ABIType, value: Any) -> bytes:
    kind = value_type.kind
    if kind in ("uint", "int"):
        if not isinstance(value, int) or isinstance(value, bool):
            raise ABIEncodingError("%s value must be an integer" % kind)
        bits = value_type.bits or 0
        minimum = 0 if kind == "uint" else -(1 << (bits - 1))
        maximum = (1 << bits) - 1 if kind == "uint" else (1 << (bits - 1)) - 1
        if value < minimum or value > maximum:
            raise ABIEncodingError("value is outside the %s%d range" % (kind, bits))
        encoded_value = value if value >= 0 else (1 << 256) + value
        return _word(encoded_value)
    if kind == "address":
        if isinstance(value, (bytes, bytearray, memoryview)):
            raw_address = bytes(value)
            if len(raw_address) != 20:
                raise ABIEncodingError("address must contain exactly 20 bytes")
        elif isinstance(value, str):
            candidate = value.removeprefix("0x")
            if len(candidate) != 40 or not _HEX_RE.fullmatch(candidate):
                raise ABIEncodingError(
                    "address must contain exactly 20 hexadecimal bytes"
                )
            raw_address = bytes.fromhex(candidate)
        else:
            raise ABIEncodingError(
                "address must be a hexadecimal string or bytes-like value"
            )
        return b"\x00" * 12 + raw_address
    if kind == "bool":
        if not isinstance(value, bool):
            raise ABIEncodingError("bool value must be True or False")
        return _word(1 if value else 0)
    if kind == "fixed_bytes":
        raw = _bytes_value(value, context="bytes%d" % value_type.size)
        if len(raw) != value_type.size:
            raise ABIEncodingError(
                "bytes%d value must contain exactly %d bytes"
                % (value_type.size, value_type.size)
            )
        return raw + b"\x00" * (_WORD_SIZE - len(raw))
    if kind == "bytes":
        raw = _bytes_value(value, context="bytes")
        return _word(len(raw)) + raw + b"\x00" * (_padded_size(len(raw)) - len(raw))
    if kind == "string":
        if not isinstance(value, str):
            raise ABIEncodingError("string value must be a string")
        raw = value.encode("utf-8")
        return _word(len(raw)) + raw + b"\x00" * (_padded_size(len(raw)) - len(raw))
    if kind == "tuple":
        tuple_values = _tuple_values(value_type.components, value)
        return _encode_container(
            [component.type for component in value_type.components], tuple_values
        )
    if kind == "array":
        if not isinstance(value, Sequence) or isinstance(
            value, (str, bytes, bytearray, memoryview)
        ):
            raise ABIEncodingError("array value must be a non-string sequence")
        if value_type.item_type is None:
            raise ABITypeError("array type has no item type")
        return _word(len(value)) + _encode_container(
            [value_type.item_type] * len(value), value
        )
    raise ABITypeError("unsupported ABI type kind: %s" % kind)


def encode_abi(
    *,
    parameters: str | Sequence[ParameterInput],
    values: Sequence[Any] | Mapping[str, Any],
) -> bytes:
    """Strictly ABI-encode top-level parameters and return bytes.

    ``values`` may be an ordered sequence or a mapping when every top-level
    parameter is named.
    """

    parsed = parse_abi_parameters(parameters)
    ordered = _tuple_values(parsed, values)
    return _encode_container([parameter.type for parameter in parsed], ordered)


def encode_abi_hex(
    *,
    parameters: str | Sequence[ParameterInput],
    values: Sequence[Any] | Mapping[str, Any],
) -> str:
    """Strictly ABI-encode top-level parameters as a ``0x`` hex string."""

    return "0x" + encode_abi(parameters=parameters, values=values).hex()


def encode_call(
    *,
    name: str,
    parameters: str | Sequence[ParameterInput],
    values: Sequence[Any] | Mapping[str, Any],
) -> bytes:
    """Return function selector plus ABI-encoded arguments."""

    parsed = parse_abi_parameters(parameters)
    return selector(name=name, parameters=parsed) + encode_abi(
        parameters=parsed, values=values
    )


def _read_word(data: bytes, position: int) -> int:
    end = position + _WORD_SIZE
    if position < 0 or end > len(data):
        raise ABIDecodingError("ABI word extends beyond the input")
    return int.from_bytes(data[position:end], "big")


def _decode_container(
    types: Sequence[ABIType], data: bytes, start: int, limit: int, max_array_length: int
) -> tuple[tuple[Any, ...], int]:
    head_size = sum(
        _WORD_SIZE if value_type.is_dynamic else value_type.static_size
        for value_type in types
    )
    head_end = start + head_size
    if head_end > limit:
        raise ABIDecodingError("ABI head extends beyond its container")

    positions: list[tuple[ABIType, int, bool]] = []
    cursor = start
    for value_type in types:
        if value_type.is_dynamic:
            offset = _read_word(data, cursor)
            if offset % _WORD_SIZE != 0:
                raise ABIDecodingError("dynamic offset is not word-aligned")
            positions.append((value_type, start + offset, True))
            cursor += _WORD_SIZE
        else:
            positions.append((value_type, cursor, False))
            cursor += value_type.static_size

    values: list[Any] = []
    expected_tail = head_end
    for value_type, position, dynamic in positions:
        if dynamic:
            if position != expected_tail:
                raise ABIDecodingError(
                    "dynamic offset is overlapping, out of order, or non-canonical"
                )
            value, consumed = _decode_value(
                value_type, data, position, limit, max_array_length
            )
            expected_tail += consumed
        else:
            value, consumed = _decode_value(
                value_type, data, position, limit, max_array_length
            )
            if consumed != value_type.static_size:
                raise ABIDecodingError("static ABI value consumed an unexpected size")
        values.append(value)
    return tuple(values), expected_tail - start


def _decode_dynamic_bytes(data: bytes, start: int, limit: int) -> tuple[bytes, int]:
    length = _read_word(data, start)
    padded = _padded_size(length)
    content_start = start + _WORD_SIZE
    end = content_start + padded
    if end > limit:
        raise ABIDecodingError("dynamic byte value extends beyond its container")
    content_end = content_start + length
    if any(data[content_end:end]):
        raise ABIDecodingError("dynamic byte padding is not zero")
    return data[content_start:content_end], _WORD_SIZE + padded


def _decode_value(
    value_type: ABIType, data: bytes, start: int, limit: int, max_array_length: int
) -> tuple[Any, int]:
    kind = value_type.kind
    if kind in ("uint", "int"):
        word = _read_word(data, start)
        bits = value_type.bits or 0
        if kind == "uint":
            if word >= 1 << bits:
                raise ABIDecodingError("uint%d has non-zero high padding" % bits)
            return word, _WORD_SIZE
        signed = word if word < 1 << 255 else word - (1 << 256)
        minimum = -(1 << (bits - 1))
        maximum = (1 << (bits - 1)) - 1
        if signed < minimum or signed > maximum:
            raise ABIDecodingError("int%d is not correctly sign-extended" % bits)
        canonical = signed if signed >= 0 else (1 << 256) + signed
        if canonical != word:
            raise ABIDecodingError("int%d is not canonically encoded" % bits)
        return signed, _WORD_SIZE
    if kind == "address":
        end = start + _WORD_SIZE
        if end > limit:
            raise ABIDecodingError("address extends beyond its container")
        word_bytes = data[start:end]
        if any(word_bytes[:12]):
            raise ABIDecodingError("address has non-zero high padding")
        return to_checksum_address(word_bytes[12:]), _WORD_SIZE
    if kind == "bool":
        word = _read_word(data, start)
        if word not in (0, 1):
            raise ABIDecodingError("bool must be encoded as zero or one")
        return bool(word), _WORD_SIZE
    if kind == "fixed_bytes":
        end = start + _WORD_SIZE
        if end > limit:
            raise ABIDecodingError("fixed bytes extend beyond their container")
        size = value_type.size or 0
        word_bytes = data[start:end]
        if any(word_bytes[size:]):
            raise ABIDecodingError("bytes%d has non-zero right padding" % size)
        return word_bytes[:size], _WORD_SIZE
    if kind == "bytes":
        return _decode_dynamic_bytes(data, start, limit)
    if kind == "string":
        raw, consumed = _decode_dynamic_bytes(data, start, limit)
        try:
            return raw.decode("utf-8", errors="strict"), consumed
        except UnicodeDecodeError as error:
            raise ABIDecodingError("string is not valid UTF-8") from error
    if kind == "tuple":
        return _decode_container(
            [component.type for component in value_type.components],
            data,
            start,
            limit,
            max_array_length,
        )
    if kind == "array":
        length = _read_word(data, start)
        if length > max_array_length:
            raise ABIDecodingError("array length exceeds max_array_length")
        if value_type.item_type is None:
            raise ABITypeError("array type has no item type")
        item_head_size = (
            _WORD_SIZE
            if value_type.item_type.is_dynamic
            else value_type.item_type.static_size
        )
        content_start = start + _WORD_SIZE
        if length and item_head_size > (limit - content_start) // length:
            raise ABIDecodingError("array head extends beyond its container")
        decoded, consumed = _decode_container(
            [value_type.item_type] * length,
            data,
            content_start,
            limit,
            max_array_length,
        )
        return list(decoded), _WORD_SIZE + consumed
    raise ABITypeError("unsupported ABI type kind: %s" % kind)


def _named_value(value_type: ABIType, value: Any) -> Any:
    if value_type.kind == "tuple":
        converted = [
            _named_value(component.type, component_value)
            for component, component_value in zip(value_type.components, value)
        ]
        if all(component.name for component in value_type.components):
            return {
                component.name: component_value
                for component, component_value in zip(value_type.components, converted)
            }
        return tuple(converted)
    if value_type.kind == "array":
        if value_type.item_type is None:
            raise ABITypeError("array type has no item type")
        return [_named_value(value_type.item_type, item) for item in value]
    return value


def _input_bytes(data: str | bytes | bytearray | memoryview) -> bytes:
    if isinstance(data, (bytes, bytearray, memoryview)):
        return bytes(data)
    if isinstance(data, str) and data.startswith("0x"):
        digits = data[2:]
        if len(digits) % 2 == 0 and _HEX_RE.fullmatch(digits):
            return bytes.fromhex(digits)
    raise TypeError("data must be bytes-like or an even-length 0x hex string")


def decode_abi(
    *,
    parameters: str | Sequence[ParameterInput],
    data: str | bytes | bytearray | memoryview,
    named: bool = False,
    max_array_length: int = 100000,
) -> tuple[Any, ...] | dict[str, Any]:
    """Strictly decode one complete ABI parameter payload.

    Offsets must be ordered and canonical, padding must be zero, and trailing
    bytes are rejected. With ``named=True``, named tuples become dictionaries;
    every top-level parameter must also be named.
    """

    if not isinstance(named, bool):
        raise TypeError("named must be a boolean")
    if (
        not isinstance(max_array_length, int)
        or isinstance(max_array_length, bool)
        or max_array_length < 0
    ):
        raise ValueError("max_array_length must be a non-negative integer")
    parsed = parse_abi_parameters(parameters)
    raw = _input_bytes(data)
    decoded, consumed = _decode_container(
        [parameter.type for parameter in parsed], raw, 0, len(raw), max_array_length
    )
    if consumed != len(raw):
        raise ABIDecodingError("ABI payload contains trailing bytes")
    converted = tuple(
        _named_value(parameter.type, value) for parameter, value in zip(parsed, decoded)
    )
    if not named:
        return converted
    if any(not parameter.name for parameter in parsed):
        raise ABIDecodingError(
            "named decoding requires every top-level parameter to be named"
        )
    return {parameter.name: value for parameter, value in zip(parsed, converted)}


def decode_abi_named(
    *,
    parameters: str | Sequence[ParameterInput],
    data: str | bytes | bytearray | memoryview,
    max_array_length: int = 100000,
) -> dict[str, Any]:
    """Decode a payload into recursively named dictionaries."""

    result = decode_abi(
        parameters=parameters, data=data, named=True, max_array_length=max_array_length
    )
    if not isinstance(result, dict):
        raise ABIDecodingError("named ABI decoding did not produce a dictionary")
    return result


__all__ = [
    "ABIDecodingError",
    "ABIEncodingError",
    "ABIError",
    "ABIParameter",
    "ABIType",
    "ABITypeError",
    "canonical_signature",
    "decode_abi",
    "decode_abi_named",
    "encode_abi",
    "encode_abi_hex",
    "encode_call",
    "parse_abi_parameter",
    "parse_abi_parameters",
    "parse_abi_type",
    "selector",
]

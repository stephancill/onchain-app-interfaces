"""Strict JSON-to-ABI response projection for External Request responses."""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from . import abi as _abi
from .keccak import is_checksum_address, keccak256, to_checksum_address

AbiParameter = getattr(_abi, "AbiParameter", None) or _abi.ABIParameter
encode_parameters = getattr(_abi, "encode_parameters", None) or _abi.encode_abi


MAX_JSON_DEPTH = 64
MAX_NODES = 128
MAX_TOTAL_VALUES = 4096
MAX_PROJECTED_BYTES = 1_048_576

_NODE_TYPES = (
    "TUPLE",
    "ARRAY",
    "BOOL",
    "UINT256_DECIMAL",
    "UINT256_HEX",
    "INT256_DECIMAL",
    "ADDRESS",
    "BYTES",
    "BYTES32",
    "STRING",
)


class _JsonParser:
    def __init__(self, text: str) -> None:
        self.text = text
        self.cursor = 0

    def parse(self) -> Any:
        value = self._value(0)
        self._whitespace()
        if self.cursor != len(self.text):
            raise ValueError("Trailing JSON content")
        return value

    def _whitespace(self) -> None:
        while self.cursor < len(self.text) and self.text[self.cursor] in " \t\n\r":
            self.cursor += 1

    def _string(self) -> str:
        if self.cursor >= len(self.text) or self.text[self.cursor] != '"':
            raise ValueError("Expected JSON string")
        self.cursor += 1
        result: list[str] = []
        escapes = {
            '"': '"',
            "\\": "\\",
            "/": "/",
            "b": "\b",
            "f": "\f",
            "n": "\n",
            "r": "\r",
            "t": "\t",
        }
        while self.cursor < len(self.text):
            character = self.text[self.cursor]
            self.cursor += 1
            if character == '"':
                return "".join(result)
            if character == "\\":
                if self.cursor >= len(self.text):
                    raise ValueError("Unterminated JSON escape")
                escaped = self.text[self.cursor]
                self.cursor += 1
                if escaped in escapes:
                    result.append(escapes[escaped])
                    continue
                if escaped != "u":
                    raise ValueError("Invalid JSON escape sequence")
                digits = self.text[self.cursor : self.cursor + 4]
                if len(digits) != 4 or re.fullmatch(r"[0-9a-fA-F]{4}", digits) is None:
                    raise ValueError("Invalid JSON unicode escape")
                self.cursor += 4
                codepoint = int(digits, 16)
                if 0xD800 <= codepoint <= 0xDBFF:
                    if self.text[self.cursor : self.cursor + 2] != "\\u":
                        raise ValueError("Unpaired JSON high surrogate")
                    low_digits = self.text[self.cursor + 2 : self.cursor + 6]
                    if (
                        len(low_digits) != 4
                        or re.fullmatch(r"[0-9a-fA-F]{4}", low_digits) is None
                    ):
                        raise ValueError("Invalid JSON unicode escape")
                    low = int(low_digits, 16)
                    if not 0xDC00 <= low <= 0xDFFF:
                        raise ValueError("Unpaired JSON high surrogate")
                    self.cursor += 6
                    codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + low - 0xDC00
                elif 0xDC00 <= codepoint <= 0xDFFF:
                    raise ValueError("Unpaired JSON low surrogate")
                result.append(chr(codepoint))
                continue
            if ord(character) < 0x20:
                raise ValueError("Unescaped control character in JSON string")
            result.append(character)
        raise ValueError("Unterminated JSON string")

    def _number(self) -> int:
        start = self.cursor
        if self.cursor < len(self.text) and self.text[self.cursor] == "-":
            self.cursor += 1
        integer_start = self.cursor
        while self.cursor < len(self.text) and "0" <= self.text[self.cursor] <= "9":
            self.cursor += 1
        token = self.text[start : self.cursor]
        if self.cursor == integer_start or token == "-":
            raise ValueError("Invalid JSON number")
        unsigned = token.removeprefix("-")
        if len(unsigned) > 1 and unsigned.startswith("0"):
            raise ValueError("Invalid JSON number leading zero")
        if self.cursor < len(self.text) and self.text[self.cursor] in ".eE":
            raise ValueError("Imprecise JSON number representation")
        return int(token)

    def _value(self, depth: int) -> Any:
        if depth > MAX_JSON_DEPTH:
            raise ValueError("JSON exceeds maximum depth")
        self._whitespace()
        if self.cursor >= len(self.text):
            raise ValueError("Unexpected end of JSON")
        character = self.text[self.cursor]
        if character == "{":
            self.cursor += 1
            result: dict[str, Any] = {}
            self._whitespace()
            if self.cursor < len(self.text) and self.text[self.cursor] == "}":
                self.cursor += 1
                return result
            while True:
                self._whitespace()
                key = self._string()
                if key in result:
                    raise ValueError("Duplicate JSON object key: %s" % key)
                self._whitespace()
                if self.cursor >= len(self.text) or self.text[self.cursor] != ":":
                    raise ValueError("Expected JSON colon")
                self.cursor += 1
                result[key] = self._value(depth + 1)
                self._whitespace()
                if self.cursor < len(self.text) and self.text[self.cursor] == ",":
                    self.cursor += 1
                    continue
                if self.cursor < len(self.text) and self.text[self.cursor] == "}":
                    self.cursor += 1
                    return result
                raise ValueError("Expected JSON comma or closing brace")
        if character == "[":
            self.cursor += 1
            values: list[Any] = []
            self._whitespace()
            if self.cursor < len(self.text) and self.text[self.cursor] == "]":
                self.cursor += 1
                return values
            while True:
                values.append(self._value(depth + 1))
                self._whitespace()
                if self.cursor < len(self.text) and self.text[self.cursor] == ",":
                    self.cursor += 1
                    continue
                if self.cursor < len(self.text) and self.text[self.cursor] == "]":
                    self.cursor += 1
                    return values
                raise ValueError("Expected JSON comma or closing bracket")
        if character == '"':
            return self._string()
        for literal, value in (("true", True), ("false", False), ("null", None)):
            if self.text.startswith(literal, self.cursor):
                self.cursor += len(literal)
                return value
        return self._number()


@dataclass
class _CompiledNode:
    kind: str
    pointer: str
    children: tuple["_CompiledNode", ...] = ()
    max_items: int = 0


def _get(value: Any, key: str) -> Any:
    if isinstance(value, Mapping):
        return value[key]
    return getattr(value, key)


def _integer(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError("%s must be a non-negative integer" % name)
    return value


def _compile_projection(nodes: Sequence[Any]) -> _CompiledNode:
    if not nodes:
        raise ValueError("Projection tree is empty")
    if len(nodes) > MAX_NODES:
        raise ValueError("Projection exceeds node limit")
    cursor = 0
    schema_values = 0

    def compile_node(depth: int) -> _CompiledNode:
        nonlocal cursor, schema_values
        if depth > MAX_JSON_DEPTH:
            raise ValueError("Projection exceeds maximum depth")
        if cursor >= len(nodes):
            raise ValueError("Incomplete projection tree")
        source = nodes[cursor]
        cursor += 1
        node_type = _get(source, "nodeType")
        if (
            isinstance(node_type, int)
            and not isinstance(node_type, bool)
            and 0 <= node_type < len(_NODE_TYPES)
        ):
            node_type = _NODE_TYPES[node_type]
        if node_type not in _NODE_TYPES:
            raise ValueError("Unsupported projection node type")
        pointer = _get(source, "pointer")
        if not isinstance(pointer, str):
            raise ValueError("Projection pointer must be a string")
        child_count = _integer(_get(source, "childCount"), "childCount")
        max_items = _integer(_get(source, "maxItems"), "maxItems")
        if node_type == "TUPLE":
            if child_count == 0:
                raise ValueError("Projection tuple must have children")
            if max_items != 0:
                raise ValueError("Projection tuple maxItems must be zero")
            children = tuple(compile_node(depth + 1) for _ in range(child_count))
            return _CompiledNode(node_type, pointer, children)
        if node_type == "ARRAY":
            if child_count != 1:
                raise ValueError("Projection array must have one element schema")
            if max_items < 1 or max_items > 256:
                raise ValueError("Invalid projection array limit")
            schema_values += 1
            return _CompiledNode(
                node_type, pointer, (compile_node(depth + 1),), max_items
            )
        if child_count != 0 or max_items != 0:
            raise ValueError("Scalar projection node cannot have children")
        schema_values += 1
        return _CompiledNode(node_type, pointer)

    root = compile_node(0)
    if cursor != len(nodes):
        raise ValueError("Projection contains trailing nodes")
    if schema_values > MAX_TOTAL_VALUES:
        raise ValueError("Projection exceeds total value limit")
    return root


def _resolve_pointer(document: Any, pointer: str) -> Any:
    if pointer == "":
        return document
    if not pointer.startswith("/"):
        raise ValueError("Invalid JSON Pointer: %s" % pointer)
    value = document
    for raw_token in pointer[1:].split("/"):
        if re.search(r"~(?:[^01]|$)", raw_token):
            raise ValueError("Invalid JSON Pointer escape: %s" % pointer)
        token = raw_token.replace("~1", "/").replace("~0", "~")
        if isinstance(value, list):
            if re.fullmatch(r"0|[1-9][0-9]*", token) is None:
                raise ValueError("Invalid JSON array index: %s" % token)
            index = int(token)
            if index >= len(value):
                raise ValueError("JSON array index does not exist: %s" % pointer)
            value = value[index]
        elif isinstance(value, dict) and token in value:
            value = value[token]
        else:
            raise ValueError("JSON Pointer does not exist: %s" % pointer)
    return value


def _coerce_scalar(kind: str, value: Any) -> Any:
    if kind == "BOOL":
        if not isinstance(value, bool):
            raise ValueError("Expected JSON boolean")
        return value
    if kind == "UINT256_DECIMAL":
        if isinstance(value, bool) or not isinstance(value, (str, int)):
            raise ValueError("Expected integer or decimal string")
        text = str(value)
        if re.fullmatch(r"0|[1-9][0-9]*", text) is None:
            raise ValueError("Invalid uint256 decimal")
        parsed = int(text)
        if parsed >= 1 << 256:
            raise ValueError("uint256 overflow")
        return parsed
    if kind == "UINT256_HEX":
        if not isinstance(value, str) or re.fullmatch(r"0x[0-9a-fA-F]+", value) is None:
            raise ValueError("Invalid hexadecimal uint256")
        parsed = int(value, 16)
        if parsed >= 1 << 256:
            raise ValueError("uint256 overflow")
        return parsed
    if kind == "INT256_DECIMAL":
        if isinstance(value, bool) or not isinstance(value, (str, int)):
            raise ValueError("Expected integer or decimal string")
        text = str(value)
        if re.fullmatch(r"-?(?:0|[1-9][0-9]*)", text) is None:
            raise ValueError("Invalid int256 decimal")
        parsed = int(text)
        if parsed < -(1 << 255) or parsed >= 1 << 255:
            raise ValueError("int256 overflow")
        return parsed
    if kind == "ADDRESS":
        if (
            not isinstance(value, str)
            or re.fullmatch(r"0x[0-9a-fA-F]{40}", value) is None
        ):
            raise ValueError("Invalid address")
        digits = value[2:]
        if (
            digits != digits.lower()
            and digits != digits.upper()
            and not is_checksum_address(value)
        ):
            raise ValueError("Invalid address checksum")
        return to_checksum_address(value)
    if kind == "BYTES":
        if (
            not isinstance(value, str)
            or re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", value) is None
        ):
            raise ValueError("Invalid byte string")
        return value
    if kind == "BYTES32":
        if (
            not isinstance(value, str)
            or re.fullmatch(r"0x[0-9a-fA-F]{64}", value) is None
        ):
            raise ValueError("Invalid bytes32")
        return value
    if kind == "STRING":
        if not isinstance(value, str):
            raise ValueError("Expected JSON string")
        return value
    raise ValueError("Unsupported scalar projection node")


def _evaluate_projection(root: _CompiledNode, document: Any) -> Any:
    value_count = 0

    def evaluate(node: _CompiledNode, context: Any) -> Any:
        nonlocal value_count
        value = _resolve_pointer(context, node.pointer)
        if node.kind == "TUPLE":
            if not isinstance(value, dict):
                raise ValueError("Expected JSON object at %s" % node.pointer)
            return tuple(evaluate(child, value) for child in node.children)
        if node.kind == "ARRAY":
            if not isinstance(value, list):
                raise ValueError("Expected JSON array at %s" % node.pointer)
            if len(value) > node.max_items:
                raise ValueError("JSON array exceeds maxItems at %s" % node.pointer)
            value_count += 1
            if value_count > MAX_TOTAL_VALUES:
                raise ValueError("Projection exceeds total value limit")
            return [evaluate(node.children[0], item) for item in value]
        value_count += 1
        if value_count > MAX_TOTAL_VALUES:
            raise ValueError("Projection exceeds total value limit")
        return _coerce_scalar(node.kind, value)

    return evaluate(root, document)


def _abi_parameter(node: _CompiledNode) -> AbiParameter:
    def parameter(
        abi_type: str, components: tuple[AbiParameter, ...] = ()
    ) -> AbiParameter:
        try:
            return AbiParameter(name="", type=abi_type, components=components)
        except TypeError:
            value: dict[str, Any] = {"name": "", "type": abi_type}
            if components:
                value["components"] = components
            return _abi.parse_abi_parameter(value)

    if node.kind == "TUPLE":
        return parameter(
            "tuple", tuple(_abi_parameter(child) for child in node.children)
        )
    if node.kind == "ARRAY":
        element = _abi_parameter(node.children[0])
        if hasattr(element.type, "canonical_type"):
            return _abi.parse_abi_parameter(element.type.canonical_type + "[]")
        return parameter(element.type + "[]", element.components)
    abi_type = {
        "BOOL": "bool",
        "UINT256_DECIMAL": "uint256",
        "UINT256_HEX": "uint256",
        "INT256_DECIMAL": "int256",
        "ADDRESS": "address",
        "BYTES": "bytes",
        "BYTES32": "bytes32",
        "STRING": "string",
    }[node.kind]
    return parameter(abi_type)


def _body_bytes(body: bytes | bytearray | memoryview | str) -> tuple[bytes, bool]:
    if isinstance(body, str):
        if re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", body) is None:
            raise ValueError("Response body must be bytes or 0x-prefixed hex")
        return bytes.fromhex(body[2:]), True
    if isinstance(body, (bytes, bytearray, memoryview)):
        return bytes(body), False
    raise TypeError("Response body must be bytes or 0x-prefixed hex")


def transform_http_response(
    *, response: Mapping[str, Any], transform: Mapping[str, Any]
) -> dict[str, Any]:
    """Apply RAW or JSON_ABI transformation and return a copied response."""

    body_bytes, hex_body = _body_bytes(response["body"])
    digest = keccak256(body_bytes)
    result = dict(response)
    result["rawBodyHash"] = "0x" + digest.hex() if hex_body else digest
    result["bodyEncoding"] = "RAW"

    kind = _get(transform, "kind")
    if kind == 0:
        kind = "RAW"
    elif kind == 1:
        kind = "JSON_ABI"
    if kind == "RAW":
        return result
    if kind != "JSON_ABI":
        raise ValueError("Unsupported response transform kind")

    status_from = _integer(_get(transform, "statusFrom"), "statusFrom")
    status_to = _integer(_get(transform, "statusTo"), "statusTo")
    status = response["status"]
    if not isinstance(status, int) or isinstance(status, bool):
        raise ValueError("Response status must be an integer")
    if status < status_from or status > status_to:
        return result

    try:
        text = body_bytes.decode("utf-8", errors="strict")
    except UnicodeError as error:
        raise ValueError("Response body is not valid UTF-8 JSON") from error
    document = _JsonParser(text).parse()
    root = _compile_projection(_get(transform, "nodes"))
    value = _evaluate_projection(root, document)
    projected = encode_parameters(parameters=(_abi_parameter(root),), values=(value,))
    projected_bytes, projected_was_hex = _body_bytes(projected)
    if len(projected_bytes) > MAX_PROJECTED_BYTES:
        raise ValueError("Projected response exceeds client limit")
    if hex_body:
        result["body"] = (
            projected if projected_was_hex else "0x" + projected_bytes.hex()
        )
    else:
        result["body"] = projected_bytes
    result["bodyEncoding"] = "JSON_ABI"
    return result


__all__ = [
    "MAX_JSON_DEPTH",
    "MAX_NODES",
    "MAX_PROJECTED_BYTES",
    "MAX_TOTAL_VALUES",
    "transform_http_response",
]

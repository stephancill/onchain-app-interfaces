"""Strict parser and ABI helpers for application descriptor profile v0.1."""

from __future__ import annotations

import json
import re
from collections.abc import Mapping, Sequence
from typing import Any

from . import abi as _abi
from .keccak import is_checksum_address, to_checksum_address

AbiParameter = getattr(_abi, "AbiParameter", None) or _abi.ABIParameter
decode_parameters = getattr(_abi, "decode_parameters", None) or _abi.decode_abi
encode_parameters = getattr(_abi, "encode_parameters", None) or _abi.encode_abi


_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_INTEGER = re.compile(r"^-?[0-9]+$")
_ABI_TYPE = re.compile(
    r"^(address|bool|string|bytes|bytes(?:[1-9]|[12][0-9]|3[0-2])|"
    r"u?int(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|"
    r"144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)?)(\[\])*$"
)
_SUPPORTED_PATTERNS = {
    "^[a-z0-9-]+$": re.compile(r"^[a-z0-9-]+$"),
    "^[A-Za-z0-9_-]+$": re.compile(r"^[A-Za-z0-9_-]+$"),
    "^[A-Z]{2}$": re.compile(r"^[A-Z]{2}$"),
}
_FIELD_KEYS = {
    "name",
    "abiType",
    "components",
    "semanticType",
    "minimum",
    "maximum",
    "minLength",
    "maxLength",
    "pattern",
    "assetField",
    "contentType",
    "sensitivity",
    "enumValues",
}


def _reject_constant(value: str) -> Any:
    raise ValueError("Invalid JSON number: %s" % value)


def _unique_object(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON object key: %s" % key)
        result[key] = value
    return result


def _strict_json(text: str) -> Any:
    try:
        return json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ValueError("Invalid descriptor JSON") from error


def _expect_object(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("%s must be an object" % context)
    return value


def _exact_keys(
    value: Mapping[str, Any],
    required: Sequence[str],
    optional: Sequence[str],
    context: str,
) -> None:
    required_set = set(required)
    allowed = required_set | set(optional)
    missing = required_set - set(value)
    unknown = set(value) - allowed
    if missing:
        raise ValueError(
            "%s is missing required field: %s" % (context, sorted(missing)[0])
        )
    if unknown:
        raise ValueError(
            "%s contains unknown field: %s" % (context, sorted(unknown)[0])
        )


def _is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _optional_string(field: Mapping[str, Any], key: str, nonempty: bool = True) -> None:
    if key not in field:
        return
    value = field[key]
    if not isinstance(value, str) or (nonempty and not value):
        raise ValueError(
            "%s must be %sa string" % (key, "a non-empty " if nonempty else "")
        )


def _core_abi_type(abi_type: str) -> tuple[str, int]:
    dimensions = 0
    while abi_type.endswith("[]"):
        dimensions += 1
        abi_type = abi_type[:-2]
    return abi_type, dimensions


def _validate_fields(value: Any, context: str) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise ValueError("%s must be an array" % context)
    names = set()
    for index, candidate in enumerate(value):
        field_context = "%s[%d]" % (context, index)
        field = _expect_object(candidate, field_context)
        _exact_keys(
            field,
            ("name", "abiType"),
            tuple(_FIELD_KEYS - {"name", "abiType"}),
            field_context,
        )

        name = field["name"]
        abi_type = field["abiType"]
        if not isinstance(name, str) or _IDENTIFIER.fullmatch(name) is None:
            raise ValueError("Invalid descriptor field name")
        if name in names:
            raise ValueError("Duplicate field: %s" % name)
        names.add(name)
        if not isinstance(abi_type, str) or not abi_type:
            raise ValueError("abiType must be a non-empty string")

        core, _ = _core_abi_type(abi_type)
        if core == "tuple":
            if "components" not in field:
                raise ValueError("Tuple fields require components")
            _validate_fields(field["components"], "%s.components" % field_context)
        else:
            if "components" in field:
                raise ValueError("Only tuple fields may have components")
            if _ABI_TYPE.fullmatch(abi_type) is None:
                raise ValueError("Unsupported descriptor ABI type: %s" % abi_type)

        for key in ("semanticType", "assetField", "contentType"):
            _optional_string(field, key)
        for key in ("minimum", "maximum"):
            if key in field and (
                not isinstance(field[key], str)
                or _INTEGER.fullmatch(field[key]) is None
            ):
                raise ValueError("%s must be a decimal integer string" % key)
        for key in ("minLength", "maxLength"):
            if key in field and (not _is_integer(field[key]) or field[key] < 0):
                raise ValueError("%s must be a non-negative integer" % key)
        if "minimum" in field and "maximum" in field:
            if int(field["minimum"]) > int(field["maximum"]):
                raise ValueError("minimum exceeds maximum")
        if "minLength" in field and "maxLength" in field:
            if field["minLength"] > field["maxLength"]:
                raise ValueError("minLength exceeds maxLength")
        if "pattern" in field:
            if (
                not isinstance(field["pattern"], str)
                or field["pattern"] not in _SUPPORTED_PATTERNS
            ):
                raise ValueError("Unsupported string pattern")
        if "sensitivity" in field and field["sensitivity"] not in (
            "public",
            "private",
            "bearer-secret",
        ):
            raise ValueError("Invalid field sensitivity")
        if "enumValues" in field:
            enum_values = _expect_object(field["enumValues"], "enumValues")
            for enum_value in enum_values.values():
                if not _is_integer(enum_value) or enum_value < 0:
                    raise ValueError("enumValues values must be non-negative integers")
    return value


def _validate_io(value: Any, output: bool = False) -> dict[str, Any]:
    result = _expect_object(value, "output" if output else "inputs")
    _exact_keys(result, ("encoding", "fields"), (), "output" if output else "inputs")
    if result["encoding"] != "abi":
        raise ValueError("Unsupported descriptor encoding")
    _validate_fields(result["fields"], ("output" if output else "inputs") + ".fields")
    return result


def parse_application_descriptor(
    value: bytes | bytearray | memoryview | str,
) -> dict[str, Any]:
    """Parse and completely validate a v0.1 query or action descriptor."""

    if isinstance(value, str):
        if value.startswith("0x"):
            try:
                raw = bytes.fromhex(value[2:])
                text = raw.decode("utf-8", errors="strict")
            except (ValueError, UnicodeError) as error:
                raise ValueError("Invalid hex-encoded descriptor") from error
        else:
            text = value
    elif isinstance(value, (bytes, bytearray, memoryview)):
        try:
            text = bytes(value).decode("utf-8", errors="strict")
        except UnicodeError as error:
            raise ValueError("Descriptor is not valid UTF-8") from error
    else:
        raise TypeError("Descriptor must be UTF-8 bytes, text, or 0x-prefixed hex")

    descriptor = _expect_object(_strict_json(text), "descriptor")
    common_required = ("version", "kind", "name", "inputs", "output")
    common_optional = ("description", "provenance")
    kind = descriptor.get("kind")
    if kind == "query":
        _exact_keys(descriptor, common_required, common_optional, "descriptor")
    elif kind == "action":
        _exact_keys(
            descriptor,
            common_required,
            common_optional + ("effects", "execution"),
            "descriptor",
        )
    else:
        raise ValueError("Unsupported descriptor kind")

    if descriptor["version"] != "0.1":
        raise ValueError("Unsupported descriptor version")
    if not isinstance(descriptor["name"], str) or not descriptor["name"]:
        raise ValueError("Descriptor name must be a non-empty string")
    _optional_string(descriptor, "description", nonempty=False)
    _validate_io(descriptor["inputs"])

    if "provenance" in descriptor:
        provenance = _expect_object(descriptor["provenance"], "provenance")
        _exact_keys(provenance, ("type",), (), "provenance")
        if provenance["type"] not in ("onchain", "configured-origin", "hybrid"):
            raise ValueError("Invalid descriptor provenance")

    if kind == "query":
        _validate_io(descriptor["output"], output=True)
        return descriptor

    output = _expect_object(descriptor["output"], "output")
    _exact_keys(output, ("encoding",), (), "output")
    if output["encoding"] != "preparedAction":
        raise ValueError("Unsupported action output encoding")
    if "effects" in descriptor:
        if not isinstance(descriptor["effects"], list):
            raise ValueError("effects must be an array")
        effect_keys = {
            "type",
            "assetField",
            "amountField",
            "minimumField",
            "chainIdField",
            "description",
        }
        for effect in descriptor["effects"]:
            item = _expect_object(effect, "effect")
            _exact_keys(item, ("type",), tuple(effect_keys - {"type"}), "effect")
            if item["type"] not in ("increase", "decrease", "set", "external"):
                raise ValueError("Invalid effect type")
            for key in effect_keys - {"type"}:
                _optional_string(item, key, nonempty=False)
    if "execution" in descriptor:
        execution = _expect_object(descriptor["execution"], "execution")
        _exact_keys(execution, ("atomicity",), (), "execution")
        if execution["atomicity"] not in ("sequential-allowed", "atomic-required"):
            raise ValueError("Invalid action atomicity")
    return descriptor


def _abi_parameter(field: Mapping[str, Any]) -> AbiParameter:
    components = tuple(
        _abi_parameter(component) for component in field.get("components", ())
    )
    try:
        return AbiParameter(
            name=field["name"], type=field["abiType"], components=components
        )
    except TypeError:
        value = {"name": field["name"], "type": field["abiType"]}
        if _core_abi_type(field["abiType"])[0] == "tuple":
            value["components"] = components
        return _abi.parse_abi_parameter(value)


def _integer_value(field: Mapping[str, Any], value: Any) -> int:
    if _is_integer(value):
        parsed = value
    elif isinstance(value, str) and _INTEGER.fullmatch(value) is not None:
        parsed = field.get("enumValues", {}).get(value, int(value))
    elif isinstance(value, str) and value in field.get("enumValues", {}):
        parsed = field["enumValues"][value]
    else:
        raise ValueError("Invalid integer value for %s" % field["name"])
    if "minimum" in field and parsed < int(field["minimum"]):
        raise ValueError("%s is below its minimum" % field["name"])
    if "maximum" in field and parsed > int(field["maximum"]):
        raise ValueError("%s exceeds its maximum" % field["name"])
    return parsed


def _normalize_scalar(field: Mapping[str, Any], core: str, value: Any) -> Any:
    if core.startswith("uint") or core.startswith("int"):
        return _integer_value(field, value)
    if core == "address":
        if (
            not isinstance(value, str)
            or re.fullmatch(r"0x[0-9a-fA-F]{40}", value) is None
        ):
            raise ValueError("Invalid address value for %s" % field["name"])
        digits = value[2:]
        if (
            digits != digits.lower()
            and digits != digits.upper()
            and not is_checksum_address(value)
        ):
            raise ValueError("Invalid address checksum for %s" % field["name"])
        return to_checksum_address(value)
    if core == "bool":
        if not isinstance(value, bool):
            raise ValueError("Invalid boolean value for %s" % field["name"])
        return value
    if core == "string":
        if not isinstance(value, str):
            raise ValueError("Invalid string value for %s" % field["name"])
        length = len(value.encode("utf-16-le", errors="surrogatepass")) // 2
        if "minLength" in field and length < field["minLength"]:
            raise ValueError("%s is shorter than its minimum length" % field["name"])
        if "maxLength" in field and length > field["maxLength"]:
            raise ValueError("%s exceeds its maximum length" % field["name"])
        pattern = field.get("pattern")
        if pattern is not None and _SUPPORTED_PATTERNS[pattern].search(value) is None:
            raise ValueError("%s does not match its required pattern" % field["name"])
        return value
    if core.startswith("bytes"):
        if (
            isinstance(value, str)
            and re.fullmatch(r"0x[0-9a-fA-F]*", value) is not None
        ):
            if len(value) % 2 != 0:
                raise ValueError("Invalid bytes value for %s" % field["name"])
            return value
        if isinstance(value, (bytes, bytearray, memoryview)):
            return bytes(value)
        raise ValueError("Invalid bytes value for %s" % field["name"])
    raise ValueError("Unsupported descriptor ABI type: %s" % field["abiType"])


def _normalize_value(field: Mapping[str, Any], value: Any) -> Any:
    core, dimensions = _core_abi_type(field["abiType"])

    def normalize(candidate: Any, remaining: int) -> Any:
        if remaining:
            if not isinstance(candidate, (list, tuple)):
                raise ValueError("Invalid array value for %s" % field["name"])
            return [normalize(item, remaining - 1) for item in candidate]
        if core == "tuple":
            if not isinstance(candidate, Mapping):
                raise ValueError("Invalid tuple value for %s" % field["name"])
            expected = {component["name"] for component in field.get("components", ())}
            if set(candidate) != expected:
                raise ValueError("Tuple fields do not match %s" % field["name"])
            return {
                component["name"]: _normalize_value(
                    component, candidate[component["name"]]
                )
                for component in field.get("components", ())
            }
        return _normalize_scalar(field, core, candidate)

    return normalize(value, dimensions)


def encode_descriptor_parameters(
    *, descriptor: Mapping[str, Any], values: Mapping[str, Any]
) -> bytes:
    """Validate and ABI-encode the named input values of a parsed descriptor."""

    fields = descriptor["inputs"]["fields"]
    parameters = tuple(_abi_parameter(field) for field in fields)
    normalized = tuple(
        _normalize_value(field, values.get(field["name"])) for field in fields
    )
    return encode_parameters(parameters=parameters, values=normalized)


def _decode_json_bytes(value: Any) -> Any:
    if isinstance(value, str) and re.fullmatch(r"0x[0-9a-fA-F]*", value) is not None:
        try:
            raw = bytes.fromhex(value[2:])
        except ValueError:
            return value
    elif isinstance(value, (bytes, bytearray, memoryview)):
        raw = bytes(value)
    else:
        return value
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeError:
        return raw.decode("utf-8", errors="replace")
    try:
        return _strict_json(text)
    except ValueError:
        return text


def _named_decoded_value(field: Mapping[str, Any], value: Any) -> Any:
    core, dimensions = _core_abi_type(field["abiType"])
    if (
        core == "bytes"
        and dimensions == 0
        and field.get("contentType") == "application/json"
        and field.get("sensitivity") != "bearer-secret"
    ):
        return _decode_json_bytes(value)
    if core != "tuple":
        return value

    def name_tuple(candidate: Any, remaining: int) -> Any:
        if remaining:
            return [name_tuple(item, remaining - 1) for item in candidate]
        result: dict[str, Any] = {}
        for index, component in enumerate(field.get("components", ())):
            if isinstance(candidate, Mapping) and component["name"] in candidate:
                item = candidate[component["name"]]
            else:
                item = candidate[index]
            result[component["name"]] = _named_decoded_value(component, item)
        return result

    return name_tuple(value, dimensions)


def decode_descriptor_result(
    *, descriptor: Mapping[str, Any], data: bytes | bytearray | memoryview | str
) -> dict[str, Any]:
    """Decode a query result and name all top-level and tuple components."""

    if descriptor.get("kind") != "query":
        raise ValueError("Descriptor is not a query descriptor")
    fields = descriptor["output"]["fields"]
    parameters = tuple(_abi_parameter(field) for field in fields)
    decoded = decode_parameters(parameters=parameters, data=data)
    return {
        field["name"]: _named_decoded_value(field, decoded[index])
        for index, field in enumerate(fields)
    }


__all__ = [
    "decode_descriptor_result",
    "encode_descriptor_parameters",
    "parse_application_descriptor",
]

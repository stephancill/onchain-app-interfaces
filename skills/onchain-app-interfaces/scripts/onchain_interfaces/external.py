"""External Request decoding, request completion, HTTPS, and continuation."""

from __future__ import annotations

import http.client
import ipaddress
import json
import re
import socket
import ssl
import urllib.parse
from collections.abc import Callable, Mapping, Sequence
from typing import Any

from .abi import decode_abi, encode_abi, selector
from .json_abi import transform_http_response
from .rpc import RpcClient, RpcError, extract_revert_data

_HEADER_NAME = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
_METHOD = re.compile(r"^[A-Z]+$")
_FORBIDDEN_REQUEST_HEADERS = {
    "connection",
    "content-length",
    "host",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}
_LOCATIONS = ("HEADER", "QUERY", "BODY")
_TRANSFORM_KINDS = ("RAW", "JSON_ABI")
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
_FORBIDDEN_IPV6_NETWORKS = tuple(
    ipaddress.ip_network(value)
    for value in ("64:ff9b::/96", "64:ff9b:1::/48", "2001::/32", "2002::/16")
)

_EXTERNAL_REQUEST_PARAMETERS = (
    {"name": "sender", "type": "address"},
    {
        "name": "request",
        "type": "tuple",
        "components": (
            {"name": "url", "type": "string"},
            {"name": "method", "type": "string"},
            {
                "name": "headers",
                "type": "tuple[]",
                "components": (
                    {"name": "name", "type": "string"},
                    {"name": "value", "type": "string"},
                ),
            },
            {"name": "body", "type": "bytes"},
            {
                "name": "requirements",
                "type": "tuple[]",
                "components": (
                    {"name": "location", "type": "uint8"},
                    {"name": "path", "type": "string"},
                    {"name": "description", "type": "string"},
                    {"name": "sensitive", "type": "bool"},
                ),
            },
        ),
    },
    {
        "name": "responseTransform",
        "type": "tuple",
        "components": (
            {"name": "kind", "type": "uint8"},
            {"name": "statusFrom", "type": "uint16"},
            {"name": "statusTo", "type": "uint16"},
            {
                "name": "nodes",
                "type": "tuple[]",
                "components": (
                    {"name": "nodeType", "type": "uint8"},
                    {"name": "pointer", "type": "string"},
                    {"name": "childCount", "type": "uint16"},
                    {"name": "maxItems", "type": "uint32"},
                ),
            },
        ),
    },
    {"name": "callbackFunction", "type": "bytes4"},
    {"name": "extraData", "type": "bytes"},
)
_EXTERNAL_REQUEST_SELECTOR = selector(
    name="ExternalRequest", parameters=_EXTERNAL_REQUEST_PARAMETERS
)
_CALLBACK_PARAMETERS = (
    {
        "name": "response",
        "type": "tuple",
        "components": (
            {"name": "status", "type": "uint16"},
            {
                "name": "headers",
                "type": "tuple[]",
                "components": (
                    {"name": "name", "type": "string"},
                    {"name": "value", "type": "string"},
                ),
            },
            {"name": "rawBodyHash", "type": "bytes32"},
            {"name": "bodyEncoding", "type": "uint8"},
            {"name": "body", "type": "bytes"},
        ),
    },
    {"name": "extraData", "type": "bytes"},
)


def canonical_origin(value: str, *, require_origin_only: bool = False) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise ValueError("Allowed origins must be absolute HTTPS origins")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("Allowed origins must not contain user info")
    if require_origin_only and (
        parsed.path not in ("", "/") or parsed.query or parsed.fragment
    ):
        raise ValueError(
            "Allowed origins must not contain paths, queries, or fragments"
        )
    host = parsed.hostname.encode("idna").decode("ascii").lower()
    port = parsed.port or 443
    display_host = "[%s]" % host if ":" in host else host
    return "https://%s%s" % (display_host, "" if port == 443 else ":%d" % port)


def decode_external_request(*, data: bytes) -> dict[str, Any]:
    if not data.startswith(_EXTERNAL_REQUEST_SELECTOR):
        raise ValueError("Revert is not ExternalRequest")
    decoded = decode_abi(
        parameters=_EXTERNAL_REQUEST_PARAMETERS,
        data=data[4:],
        named=True,
        max_array_length=4096,
    )
    request = decoded["request"]
    transform = decoded["responseTransform"]
    for requirement in request["requirements"]:
        location = requirement["location"]
        if location >= len(_LOCATIONS):
            raise ValueError("Unsupported request requirement location")
        requirement["location"] = _LOCATIONS[location]
    kind = transform["kind"]
    if kind >= len(_TRANSFORM_KINDS):
        raise ValueError("Unsupported response transform kind")
    transform["kind"] = _TRANSFORM_KINDS[kind]
    for node in transform["nodes"]:
        node_type = node["nodeType"]
        if node_type >= len(_NODE_TYPES):
            raise ValueError("Unsupported JSON ABI node type")
        node["nodeType"] = _NODE_TYPES[node_type]
    if transform["statusFrom"] > transform["statusTo"]:
        raise ValueError("Response transform status range is reversed")
    if transform["kind"] == "RAW" and transform["nodes"]:
        raise ValueError("RAW response transform must not contain nodes")
    return decoded


def validate_request(*, request: Mapping[str, Any]) -> None:
    parsed = urllib.parse.urlsplit(request["url"])
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise ValueError("External request URL must use HTTPS")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("External request URL must not contain user info")
    if parsed.fragment:
        raise ValueError("External request URL must not contain a fragment")
    if (
        not isinstance(request["method"], str)
        or _METHOD.fullmatch(request["method"]) is None
    ):
        raise ValueError("External request method must be uppercase ASCII")
    names: set[str] = set()
    for header in request["headers"]:
        name = header["name"]
        value = header["value"]
        if not isinstance(name, str) or _HEADER_NAME.fullmatch(name) is None:
            raise ValueError("Invalid HTTP header name")
        if not isinstance(value, str) or "\r" in value or "\n" in value:
            raise ValueError("Invalid HTTP header value")
        lowered = name.lower()
        if lowered in names:
            raise ValueError("Duplicate HTTP header")
        if lowered in _FORBIDDEN_REQUEST_HEADERS:
            raise ValueError("External request controls a forbidden HTTP header")
        names.add(lowered)
    requirement_keys: set[str] = set()
    for requirement in request["requirements"]:
        location = requirement["location"]
        path = requirement["path"]
        if location not in _LOCATIONS or not isinstance(path, str):
            raise ValueError("Invalid request requirement")
        normalized = path.lower() if location == "HEADER" else path
        key = "%s:%s" % (location, normalized)
        if key in requirement_keys:
            raise ValueError("Duplicate request requirement")
        requirement_keys.add(key)
        if location == "HEADER":
            if _HEADER_NAME.fullmatch(path) is None:
                raise ValueError("Invalid required HTTP header name")
            if normalized in names:
                raise ValueError("Required HTTP header is already present")


def _form_quote(value: str) -> str:
    raw = value.encode("utf-8", errors="strict")
    safe = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._"
    result = []
    for byte in raw:
        if byte == 0x20:
            result.append("+")
        elif byte in safe:
            result.append(chr(byte))
        else:
            result.append("%%%02X" % byte)
    return "".join(result)


def _parse_form(value: str) -> list[tuple[str, str]]:
    return urllib.parse.parse_qsl(value, keep_blank_values=True, strict_parsing=False)


def _serialize_form(entries: Sequence[tuple[str, str]]) -> str:
    return "&".join(
        "%s=%s" % (_form_quote(name), _form_quote(value)) for name, value in entries
    )


def _pointer_tokens(pointer: str) -> list[str]:
    if pointer == "":
        return []
    if not pointer.startswith("/"):
        raise ValueError("Invalid JSON Pointer")
    tokens = []
    for token in pointer[1:].split("/"):
        if re.search(r"~(?:[^01]|$)", token):
            raise ValueError("Invalid JSON Pointer escape")
        tokens.append(token.replace("~1", "/").replace("~0", "~"))
    return tokens


def _insert_json(document: Any, pointer: str, value: str) -> Any:
    tokens = _pointer_tokens(pointer)
    if not tokens:
        return value
    parent = document
    for token in tokens[:-1]:
        if not isinstance(parent, dict) or token not in parent:
            raise ValueError("JSON Pointer parent does not exist")
        parent = parent[token]
    if not isinstance(parent, dict) or tokens[-1] == "-":
        raise ValueError("JSON Pointer parent is not an object")
    parent[tokens[-1]] = value
    return document


def complete_request(
    *,
    request: Mapping[str, Any],
    resolve_requirement: Callable[[Mapping[str, Any]], str],
) -> tuple[dict[str, Any], list[tuple[Mapping[str, Any], str]]]:
    parsed = urllib.parse.urlsplit(request["url"])
    headers = [dict(header) for header in request["headers"]]
    body = bytes(request["body"])
    query = _parse_form(parsed.query)
    content_types = [
        header["value"].split(";", 1)[0].strip().lower()
        for header in headers
        if header["name"].lower() == "content-type"
    ]
    if len(content_types) > 1:
        raise ValueError("External request has multiple Content-Type headers")
    media_type = content_types[0] if content_types else None
    resolved: list[tuple[Mapping[str, Any], str]] = []
    json_document: Any = None
    form: list[tuple[str, str]] | None = None
    for requirement in request["requirements"]:
        value = resolve_requirement(requirement)
        if not isinstance(value, str):
            raise ValueError("Request requirement resolver must return a string")
        if requirement["location"] == "HEADER" and ("\r" in value or "\n" in value):
            raise ValueError("Invalid required HTTP header value")
        resolved.append((requirement, value))
        if requirement["location"] == "HEADER":
            headers.append({"name": requirement["path"], "value": value})
        elif requirement["location"] == "QUERY":
            if any(name == requirement["path"] for name, _ in query):
                raise ValueError("Required query parameter is already present")
            query.append((requirement["path"], value))
        elif media_type == "application/json":
            if json_document is None:
                json_document = json.loads(body.decode("utf-8", errors="strict"))
            json_document = _insert_json(json_document, requirement["path"], value)
        elif media_type == "application/x-www-form-urlencoded":
            if form is None:
                form = _parse_form(body.decode("utf-8", errors="strict"))
            if any(name == requirement["path"] for name, _ in form):
                raise ValueError("Required form field is already present")
            form.append((requirement["path"], value))
        else:
            raise ValueError("Unsupported Content-Type for body requirement")
    if json_document is not None:
        body = json.dumps(
            json_document, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
    if form is not None:
        body = _serialize_form(form).encode("ascii")
    url = urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path, _serialize_form(query), "")
    )
    return {
        "url": url,
        "method": request["method"],
        "headers": headers,
        "body": body,
    }, resolved


def _resolved_addresses(
    *, hostname: str, port: int
) -> list[tuple[int, tuple[Any, ...]]]:
    try:
        answers = socket.getaddrinfo(
            hostname,
            port,
            family=socket.AF_UNSPEC,
            type=socket.SOCK_STREAM,
            proto=socket.IPPROTO_TCP,
        )
    except socket.gaierror:
        raise RuntimeError("External request DNS resolution failed") from None
    approved: list[tuple[int, tuple[Any, ...]]] = []
    seen = set()
    for family, _, _, _, sockaddr in answers:
        address = ipaddress.ip_address(sockaddr[0])
        mapped = getattr(address, "ipv4_mapped", None)
        policy_address = mapped if mapped is not None else address
        prohibited_transition = isinstance(address, ipaddress.IPv6Address) and any(
            address in network for network in _FORBIDDEN_IPV6_NETWORKS
        )
        if (
            not policy_address.is_global
            or policy_address.is_multicast
            or prohibited_transition
        ):
            raise ValueError("External request DNS resolved to a prohibited address")
        key = (family, sockaddr)
        if key not in seen:
            seen.add(key)
            approved.append((family, sockaddr))
    if not approved:
        raise RuntimeError("External request DNS returned no addresses")
    return approved


class _PinnedHttpsConnection(http.client.HTTPSConnection):
    def __init__(
        self,
        *,
        hostname: str,
        port: int,
        family: int,
        sockaddr: tuple[Any, ...],
        timeout: float,
    ) -> None:
        context = ssl.create_default_context()
        if hasattr(ssl, "TLSVersion"):
            context.minimum_version = ssl.TLSVersion.TLSv1_2
        super().__init__(hostname, port=port, timeout=timeout, context=context)
        self._family = family
        self._sockaddr = sockaddr

    def connect(self) -> None:
        raw = socket.socket(self._family, socket.SOCK_STREAM, socket.IPPROTO_TCP)
        raw.settimeout(self.timeout)
        try:
            raw.connect(self._sockaddr)
            peer = ipaddress.ip_address(raw.getpeername()[0])
            expected = ipaddress.ip_address(self._sockaddr[0])
            if peer != expected:
                raise OSError("peer address changed")
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except Exception:
            raw.close()
            raise


def execute_https_request(
    *,
    request: Mapping[str, Any],
    allowed_origins: set[str],
    max_response_bytes: int,
    max_header_bytes: int,
    timeout: float,
    resolved_addresses: list[tuple[int, tuple[Any, ...]]] | None = None,
) -> dict[str, Any]:
    origin = canonical_origin(request["url"])
    if origin not in allowed_origins:
        raise ValueError("External request origin is not allowed: %s" % origin)
    parsed = urllib.parse.urlsplit(request["url"])
    hostname = parsed.hostname.encode("idna").decode("ascii").lower()
    port = parsed.port or 443
    addresses = resolved_addresses or _resolved_addresses(hostname=hostname, port=port)
    target = urllib.parse.urlunsplit(("", "", parsed.path or "/", parsed.query, ""))
    headers = {header["name"]: header["value"] for header in request["headers"]}
    body = request["body"] if request["body"] else None
    for family, sockaddr in addresses:
        connection = _PinnedHttpsConnection(
            hostname=hostname,
            port=port,
            family=family,
            sockaddr=sockaddr,
            timeout=timeout,
        )
        try:
            connection.request(request["method"], target, body=body, headers=headers)
            response = connection.getresponse()
            response_headers = response.getheaders()
            header_size = sum(
                len(name.encode("latin-1")) + len(value.encode("latin-1")) + 4
                for name, value in response_headers
            )
            if header_size > max_header_bytes:
                raise ValueError("HTTP response headers exceed client limit")
            declared = response.getheader("Content-Length")
            if declared is not None:
                try:
                    if int(declared) > max_response_bytes:
                        raise ValueError("HTTP response exceeds client limit")
                except ValueError as error:
                    if str(error) == "HTTP response exceeds client limit":
                        raise
                    raise ValueError(
                        "HTTP response has invalid Content-Length"
                    ) from None
            chunks = []
            remaining = max_response_bytes
            while True:
                chunk = response.read(min(65_536, remaining + 1))
                if not chunk:
                    break
                if len(chunk) > remaining:
                    raise ValueError("HTTP response exceeds client limit")
                chunks.append(chunk)
                remaining -= len(chunk)
            return {
                "status": response.status,
                "headers": [
                    {"name": name, "value": value} for name, value in response_headers
                ],
                "rawBodyHash": b"",
                "bodyEncoding": "RAW",
                "body": b"".join(chunks),
            }
        except ValueError:
            raise
        except (OSError, ssl.SSLError, http.client.HTTPException):
            pass
        finally:
            connection.close()
    raise RuntimeError("External HTTPS request failed") from None


def encode_callback(
    *, callback_function: bytes, response: Mapping[str, Any], extra_data: bytes
) -> bytes:
    encoding = response["bodyEncoding"]
    if encoding not in _TRANSFORM_KINDS:
        raise ValueError("Unsupported response body encoding")
    value = {
        "status": response["status"],
        "headers": response["headers"],
        "rawBodyHash": response["rawBodyHash"],
        "bodyEncoding": _TRANSFORM_KINDS.index(encoding),
        "body": response["body"],
    }
    return callback_function + encode_abi(
        parameters=_CALLBACK_PARAMETERS,
        values={"response": value, "extraData": extra_data},
    )


def resolve_call(
    *,
    rpc: RpcClient,
    to: str,
    data: bytes,
    block: str,
    allowed_origins: set[str],
    resolve_requirement: Callable[[Mapping[str, Any]], str],
    on_external_request: Callable[[str, str], None] | None = None,
    max_requests: int = 4,
    max_response_bytes: int = 1_048_576,
    max_header_bytes: int = 65_536,
    timeout: float = 30.0,
) -> bytes:
    call_to = to
    call_data = data
    for request_count in range(max_requests + 1):
        try:
            return rpc.eth_call(to=call_to, data=call_data, block=block)
        except RpcError as error:
            revert_data = extract_revert_data(error)
            if revert_data is None or not revert_data.startswith(
                _EXTERNAL_REQUEST_SELECTOR
            ):
                raise
            if request_count >= max_requests:
                raise RuntimeError("External request limit exceeded") from None
            external = decode_external_request(data=revert_data)
            if external["sender"].lower() != call_to.lower():
                raise ValueError("ExternalRequest sender does not match called address")
            request = external["request"]
            validate_request(request=request)
            origin = canonical_origin(request["url"])
            if origin not in allowed_origins:
                raise ValueError("External request origin is not allowed: %s" % origin)
            parsed_url = urllib.parse.urlsplit(request["url"])
            hostname = parsed_url.hostname.encode("idna").decode("ascii").lower()
            port = parsed_url.port or 443
            addresses = _resolved_addresses(hostname=hostname, port=port)
            completed, requirements = complete_request(
                request=request, resolve_requirement=resolve_requirement
            )
            if on_external_request is not None:
                on_external_request(completed["method"], origin)
            response = execute_https_request(
                request=completed,
                allowed_origins=allowed_origins,
                max_response_bytes=max_response_bytes,
                max_header_bytes=max_header_bytes,
                timeout=timeout,
                resolved_addresses=addresses,
            )
            transformed = transform_http_response(
                response=response, transform=external["responseTransform"]
            )
            for requirement, secret in requirements:
                if not requirement["sensitive"] or not secret:
                    continue
                secret_bytes = secret.encode("utf-8")
                if secret_bytes in transformed["body"] or any(
                    secret in header["name"] or secret in header["value"]
                    for header in transformed["headers"]
                ):
                    raise ValueError(
                        "Sensitive requirement was reflected in the HTTP response"
                    )
            call_to = external["sender"]
            call_data = encode_callback(
                callback_function=external["callbackFunction"],
                response=transformed,
                extra_data=external["extraData"],
            )
    raise RuntimeError("External request resolution terminated unexpectedly")


__all__ = [
    "canonical_origin",
    "complete_request",
    "decode_external_request",
    "encode_callback",
    "execute_https_request",
    "resolve_call",
    "validate_request",
]

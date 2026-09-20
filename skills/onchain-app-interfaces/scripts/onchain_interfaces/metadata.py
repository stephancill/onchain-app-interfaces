"""Required ERC-7572 application metadata and bounded URI resolution."""

from __future__ import annotations

import base64
import json
import re
import urllib.parse
from typing import Any

from .external import canonical_origin, execute_https_request

MAX_METADATA_BYTES = 65_536
MAX_METADATA_URI_BYTES = 3 * MAX_METADATA_BYTES + 256
_URI = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:\S+$")
_DATA = re.compile(
    r"^data:application/json(?:;utf8|;charset=utf-8)?(;base64)?,([\s\S]*)$",
    re.IGNORECASE,
)


def _reject_constant(value: str) -> None:
    raise ValueError("Invalid JSON constant")


def parse_contract_metadata(*, body: bytes) -> dict[str, Any]:
    try:
        if len(body) > MAX_METADATA_BYTES:
            raise ValueError("Metadata exceeds client size limit")
        value = json.loads(
            body.decode("utf-8", errors="strict"), parse_constant=_reject_constant
        )
        if not isinstance(value, dict):
            raise ValueError("Metadata must be an object")
        for field in ("name", "description"):
            if not isinstance(value.get(field), str) or not value[field].strip():
                raise ValueError("Missing nonempty metadata text")
        if "symbol" in value and not isinstance(value["symbol"], str):
            raise ValueError("Invalid symbol")
        for field in ("image", "banner_image", "featured_image", "external_link"):
            if field in value and (
                not isinstance(value[field], str)
                or _URI.fullmatch(value[field]) is None
            ):
                raise ValueError("Invalid metadata URI")
        if "collaborators" in value and (
            not isinstance(value["collaborators"], list)
            or any(not isinstance(item, str) for item in value["collaborators"])
        ):
            raise ValueError("Invalid collaborators")
        return value
    except (ValueError, UnicodeError, RecursionError) as error:
        raise ValueError(
            "Invalid application metadata: expected ERC-7572 JSON with nonempty name and description"
        ) from error


def _unquote(*, value: str) -> bytes:
    if re.search(r"%(?![0-9a-fA-F]{2})", value):
        raise ValueError("Invalid percent escape")
    return urllib.parse.unquote_to_bytes(value)


def _remote_url(*, uri: str, ipfs_gateway: str | None) -> str:
    if uri.startswith("https://"):
        return uri
    if not uri.startswith("ipfs://"):
        raise ValueError("Unsupported metadata URI scheme")
    if not ipfs_gateway:
        raise ValueError("IPFS requires a configured HTTPS gateway")
    gateway = canonical_origin(ipfs_gateway, require_origin_only=True)
    match = re.fullmatch(r"ipfs://([a-zA-Z0-9]+)((?:/[^?#]*)?)", uri)
    if match is None:
        raise ValueError("Invalid IPFS URI")
    segments = []
    for segment in match[2].split("/")[1:]:
        decoded = _unquote(value=segment).decode("utf-8", errors="strict")
        if decoded in (".", "..") or "/" in decoded or "\\" in decoded:
            raise ValueError("Invalid IPFS path")
        segments.append(urllib.parse.quote(decoded, safe="~!*'()-._"))
    suffix = "/" + "/".join(segments) if segments else ""
    return gateway + "/ipfs/" + match[1] + suffix


def resolve_contract_metadata(
    *,
    uri: str,
    allowed_origins: set[str],
    ipfs_gateway: str | None = None,
    max_header_bytes: int = 65_536,
    timeout: float = 30.0,
) -> dict[str, Any]:
    if not uri:
        raise ValueError("Invalid application metadata: contractURI() is empty")
    if (
        len(uri) > MAX_METADATA_URI_BYTES
        or len(uri.encode("utf-8")) > MAX_METADATA_URI_BYTES
    ):
        raise ValueError("Metadata exceeds client size limit")
    if uri.lower().startswith("data:"):
        try:
            match = _DATA.fullmatch(uri)
            if match is None:
                raise ValueError("Unsupported JSON data URI encoding")
            body = _unquote(value=match[2])
            if match[1]:
                encoded = body
                body = base64.b64decode(encoded, validate=True)
                if base64.b64encode(body) != encoded:
                    raise ValueError("Noncanonical Base64")
            return parse_contract_metadata(body=body)
        except (ValueError, UnicodeError) as error:
            raise ValueError("Invalid application metadata data URI") from error
    try:
        url = _remote_url(uri=uri, ipfs_gateway=ipfs_gateway)
        response = execute_https_request(
            request={
                "url": url,
                "method": "GET",
                "headers": [{"name": "Accept", "value": "application/json"}],
                "body": b"",
            },
            allowed_origins=allowed_origins,
            max_response_bytes=MAX_METADATA_BYTES,
            max_header_bytes=max_header_bytes,
            timeout=timeout,
        )
        if not 200 <= response["status"] < 300:
            raise ValueError("Metadata HTTP status %d" % response["status"])
    except (ValueError, RuntimeError, OSError) as error:
        raise RuntimeError("Metadata resolution failed: %s" % error) from error
    return parse_contract_metadata(body=response["body"])

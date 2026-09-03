"""Minimal JSON-RPC client that preserves EVM revert data."""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from collections.abc import Sequence
from typing import Any

_HEX_BYTES = re.compile(r"^0x(?:[0-9a-fA-F]{2})*$")


class RpcError(RuntimeError):
    """A redacted JSON-RPC error with its structured payload retained."""

    def __init__(self, *, method: str, error: Any) -> None:
        super().__init__("JSON-RPC %s failed" % method)
        self.method = method
        self.error = error


class RpcClient:
    def __init__(self, *, url: str, timeout: float = 30.0) -> None:
        if not isinstance(url, str) or not url.startswith(("http://", "https://")):
            raise ValueError("RPC URL must use HTTP or HTTPS")
        if timeout <= 0:
            raise ValueError("RPC timeout must be positive")
        self.url = url
        self.timeout = timeout
        self._request_id = 0

    def request(self, *, method: str, params: Sequence[Any]) -> Any:
        self._request_id += 1
        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": self._request_id,
                "method": method,
                "params": list(params),
            },
            separators=(",", ":"),
        ).encode("utf-8")
        request = urllib.request.Request(
            self.url,
            data=body,
            headers={
                "Content-Type": "application/json",
                "User-Agent": "onchain-app-interfaces-python/0.1",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8", errors="strict"))
        except (urllib.error.URLError, UnicodeError, json.JSONDecodeError):
            raise RuntimeError("JSON-RPC transport failed") from None
        if not isinstance(payload, dict) or payload.get("jsonrpc") != "2.0":
            raise RuntimeError("JSON-RPC returned an invalid response")
        if "error" in payload:
            raise RpcError(method=method, error=payload["error"])
        if "result" not in payload:
            raise RuntimeError("JSON-RPC response has no result")
        return payload["result"]

    def chain_id(self) -> int:
        return _quantity(self.request(method="eth_chainId", params=[]), "chain ID")

    def block_number(self) -> int:
        return _quantity(
            self.request(method="eth_blockNumber", params=[]), "block number"
        )

    def get_code(self, *, address: str, block: str) -> bytes:
        return _hex_bytes(
            self.request(method="eth_getCode", params=[address, block]), "contract code"
        )

    def eth_call(self, *, to: str, data: bytes, block: str) -> bytes:
        result = self.request(
            method="eth_call", params=[{"to": to, "data": "0x" + data.hex()}, block]
        )
        return _hex_bytes(result, "eth_call result")


def _quantity(value: Any, context: str) -> int:
    if (
        not isinstance(value, str)
        or re.fullmatch(r"0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)", value) is None
    ):
        raise RuntimeError("JSON-RPC returned an invalid %s" % context)
    return int(value, 16)


def _hex_bytes(value: Any, context: str) -> bytes:
    if not isinstance(value, str) or _HEX_BYTES.fullmatch(value) is None:
        raise RuntimeError("JSON-RPC returned invalid %s bytes" % context)
    return bytes.fromhex(value[2:])


def extract_revert_data(value: Any) -> bytes | None:
    """Find byte-shaped revert data in provider-specific nested error payloads."""

    seen = set()

    def visit(candidate: Any) -> bytes | None:
        identity = id(candidate)
        if identity in seen:
            return None
        seen.add(identity)
        if isinstance(candidate, str) and _HEX_BYTES.fullmatch(candidate):
            return bytes.fromhex(candidate[2:])
        if isinstance(candidate, dict):
            for key in ("data", "error", "originalError", "cause", "details"):
                if key in candidate:
                    found = visit(candidate[key])
                    if found is not None:
                        return found
            for nested in candidate.values():
                found = visit(nested)
                if found is not None:
                    return found
        if isinstance(candidate, (list, tuple)):
            for nested in candidate:
                found = visit(nested)
                if found is not None:
                    return found
        return None

    if isinstance(value, RpcError):
        return visit(value.error)
    return visit(value)


__all__ = ["RpcClient", "RpcError", "extract_revert_data"]

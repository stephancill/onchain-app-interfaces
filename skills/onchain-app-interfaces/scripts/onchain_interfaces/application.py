"""High-level discovery, query, and action-preparation client."""

from __future__ import annotations

import re
import time
from collections.abc import Callable, Mapping, Sequence
from typing import Any

from .abi import decode_abi, encode_call
from .descriptor import (
    decode_descriptor_result,
    encode_descriptor_parameters,
    parse_application_descriptor,
)
from .external import resolve_call
from .keccak import to_checksum_address
from .rpc import RpcClient, RpcError

_ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
_BYTES32 = re.compile(r"^0x[0-9a-fA-F]{64}$")

_NO_PARAMETERS: tuple[Mapping[str, Any], ...] = ()
_BYTES32_ARRAY_OUTPUT = ({"name": "ids", "type": "bytes32[]"},)
_BYTES_OUTPUT = ({"name": "value", "type": "bytes"},)
_ID_PARAMETER = ({"name": "id", "type": "bytes32"},)
_QUERY_PARAMETERS = (
    {"name": "id", "type": "bytes32"},
    {"name": "parameters", "type": "bytes"},
)
_PREPARE_PARAMETERS = (
    {"name": "id", "type": "bytes32"},
    {"name": "account", "type": "address"},
    {"name": "parameters", "type": "bytes"},
)
_PREPARED_ACTION_OUTPUT = (
    {
        "name": "preparedAction",
        "type": "tuple",
        "components": (
            {
                "name": "calls",
                "type": "tuple[]",
                "components": (
                    {"name": "target", "type": "address"},
                    {"name": "value", "type": "uint256"},
                    {"name": "data", "type": "bytes"},
                ),
            },
            {"name": "validUntil", "type": "uint256"},
        ),
    },
)


class ApplicationClient:
    """One adapter bound to an RPC endpoint and explicit HTTP policy."""

    def __init__(
        self,
        *,
        rpc_url: str,
        chain_id: int,
        adapter: str,
        allowed_origins: Sequence[str] = (),
        resolve_requirement: Callable[[Mapping[str, Any]], str] | None = None,
        max_requests: int = 4,
        max_response_bytes: int = 1_048_576,
        max_header_bytes: int = 65_536,
        timeout: float = 30.0,
    ) -> None:
        if not isinstance(chain_id, int) or isinstance(chain_id, bool) or chain_id <= 0:
            raise ValueError("Chain ID must be a positive integer")
        if not isinstance(adapter, str) or _ADDRESS.fullmatch(adapter) is None:
            raise ValueError("Adapter must be a 20-byte address")
        from .external import canonical_origin

        self.rpc = RpcClient(url=rpc_url, timeout=timeout)
        self.chain_id = chain_id
        self.adapter = to_checksum_address(adapter)
        self.allowed_origins: set[str] = {
            canonical_origin(origin, require_origin_only=True)
            for origin in allowed_origins
        }
        self.resolve_requirement = resolve_requirement or self._missing_requirement
        self.max_requests = max_requests
        self.max_response_bytes = max_response_bytes
        self.max_header_bytes = max_header_bytes
        self.timeout = timeout

    @staticmethod
    def _missing_requirement(requirement: Mapping[str, Any]) -> str:
        raise ValueError(
            "Missing External Request value for %s:%s"
            % (requirement["location"], requirement["path"])
        )

    def _verify_target(self) -> str:
        actual_chain_id = self.rpc.chain_id()
        if actual_chain_id != self.chain_id:
            raise ValueError(
                "RPC chain ID %d does not match expected chain ID %d"
                % (actual_chain_id, self.chain_id)
            )
        block = hex(self.rpc.block_number())
        if not self.rpc.get_code(address=self.adapter, block=block):
            raise ValueError("Adapter address has no bytecode")
        return block

    def _plain_call(
        self, *, name: str, parameters: Sequence[Any], values: Sequence[Any], block: str
    ) -> bytes:
        data = encode_call(name=name, parameters=parameters, values=values)
        return self.rpc.eth_call(to=self.adapter, data=data, block=block)

    def _capabilities(
        self, *, kind: str, block: str, raw_ids_result: bytes
    ) -> list[dict[str, Any]]:
        descriptor_function = (
            "queryDescriptor" if kind == "query" else "actionDescriptor"
        )
        decoded_ids = decode_abi(
            parameters=_BYTES32_ARRAY_OUTPUT, data=raw_ids_result, named=True
        )["ids"]
        capabilities = []
        for raw_id in decoded_ids:
            descriptor_result = self._plain_call(
                name=descriptor_function,
                parameters=_ID_PARAMETER,
                values=(raw_id,),
                block=block,
            )
            descriptor_bytes = decode_abi(
                parameters=_BYTES_OUTPUT, data=descriptor_result, named=True
            )["value"]
            descriptor = parse_application_descriptor(descriptor_bytes)
            if descriptor["kind"] != kind:
                raise ValueError(
                    "Capability %s has a non-%s descriptor"
                    % ("0x" + raw_id.hex(), kind)
                )
            capabilities.append({"id": "0x" + raw_id.hex(), "descriptor": descriptor})
        return capabilities

    def discover(self) -> dict[str, Any]:
        block = self._verify_target()
        unsupported = []
        try:
            query_ids = self._plain_call(
                name="queries", parameters=_NO_PARAMETERS, values=(), block=block
            )
        except RpcError:
            queries = []
            unsupported.append("Application Queries")
        else:
            queries = self._capabilities(
                kind="query", block=block, raw_ids_result=query_ids
            )
        try:
            action_ids = self._plain_call(
                name="actions", parameters=_NO_PARAMETERS, values=(), block=block
            )
        except RpcError:
            actions = []
            unsupported.append("Application Actions")
        else:
            actions = self._capabilities(
                kind="action", block=block, raw_ids_result=action_ids
            )
        if len(unsupported) == 2:
            raise ValueError(
                "Contract exposes neither Application Queries nor Application Actions"
            )
        return {
            "chainId": self.chain_id,
            "adapter": self.adapter,
            "rpcUrl": self.rpc.url,
            "block": int(block, 16),
            "queries": queries,
            "actions": actions,
            "unsupported": unsupported,
        }

    @staticmethod
    def select_capability(
        *,
        discovery: Mapping[str, Any],
        kind: str,
        identifier: str | None,
        name: str | None,
    ) -> Mapping[str, Any]:
        capabilities = discovery["queries" if kind == "query" else "actions"]
        if identifier is not None:
            if _BYTES32.fullmatch(identifier) is None:
                raise ValueError("Capability ID must be bytes32 hex")
            matches = [
                item
                for item in capabilities
                if item["id"].lower() == identifier.lower()
            ]
        else:
            matches = [
                item for item in capabilities if item["descriptor"]["name"] == name
            ]
        if not matches:
            raise ValueError("Requested %s capability was not discovered" % kind)
        if len(matches) != 1:
            raise ValueError("Capability selection is ambiguous")
        return matches[0]

    def _resolved_call(
        self, *, data: bytes, block: str, external_requests: list[dict[str, str]]
    ) -> bytes:
        return resolve_call(
            rpc=self.rpc,
            to=self.adapter,
            data=data,
            block=block,
            allowed_origins=self.allowed_origins,
            resolve_requirement=self.resolve_requirement,
            on_external_request=lambda method, origin: external_requests.append(
                {"method": method, "origin": origin}
            ),
            max_requests=self.max_requests,
            max_response_bytes=self.max_response_bytes,
            max_header_bytes=self.max_header_bytes,
            timeout=self.timeout,
        )

    def query(
        self, *, capability: Mapping[str, Any], values: Mapping[str, Any], block: str
    ) -> dict[str, Any]:
        descriptor = capability["descriptor"]
        if descriptor["kind"] != "query":
            raise ValueError("Capability is not a query")
        encoded_parameters = encode_descriptor_parameters(
            descriptor=descriptor, values=values
        )
        data = encode_call(
            name="query",
            parameters=_QUERY_PARAMETERS,
            values=(capability["id"], encoded_parameters),
        )
        external_requests: list[dict[str, str]] = []
        raw = self._resolved_call(
            data=data, block=block, external_requests=external_requests
        )
        inner = decode_abi(parameters=_BYTES_OUTPUT, data=raw, named=True)["value"]
        return {
            "capability": capability,
            "encodedParameters": encoded_parameters,
            "result": decode_descriptor_result(descriptor=descriptor, data=inner),
            "externalRequests": external_requests,
        }

    def prepare(
        self,
        *,
        capability: Mapping[str, Any],
        account: str,
        values: Mapping[str, Any],
        block: str,
    ) -> dict[str, Any]:
        descriptor = capability["descriptor"]
        if descriptor["kind"] != "action":
            raise ValueError("Capability is not an action")
        if not isinstance(account, str) or _ADDRESS.fullmatch(account) is None:
            raise ValueError("Action account must be a 20-byte address")
        account = to_checksum_address(account)
        encoded_parameters = encode_descriptor_parameters(
            descriptor=descriptor, values=values
        )
        data = encode_call(
            name="prepare",
            parameters=_PREPARE_PARAMETERS,
            values=(capability["id"], account, encoded_parameters),
        )
        external_requests: list[dict[str, str]] = []
        raw = self._resolved_call(
            data=data, block=block, external_requests=external_requests
        )
        prepared = decode_abi(parameters=_PREPARED_ACTION_OUTPUT, data=raw, named=True)[
            "preparedAction"
        ]
        if prepared["validUntil"] != 0 and int(time.time()) > prepared["validUntil"]:
            raise ValueError("Prepared action is expired")
        return {
            "capability": capability,
            "account": account,
            "encodedParameters": encoded_parameters,
            "preparedAction": prepared,
            "externalRequests": external_requests,
        }


__all__ = ["ApplicationClient"]

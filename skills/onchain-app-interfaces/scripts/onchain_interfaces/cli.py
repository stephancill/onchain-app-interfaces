"""Command-line interface for the dependency-free application client."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from collections.abc import Mapping, Sequence
from typing import Any

from .application import ApplicationClient


def _json_value(value: Any) -> Any:
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return value
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float) and math.isfinite(value):
        return value
    if isinstance(value, (bytes, bytearray, memoryview)):
        return "0x" + bytes(value).hex()
    if isinstance(value, Mapping):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    raise TypeError("Result contains an unsupported JSON value")


def _read_values(path: str) -> Mapping[str, Any]:
    try:
        if path == "-":
            value = json.load(sys.stdin)
        else:
            with open(path, "r", encoding="utf-8") as handle:
                value = json.load(handle)
    except (OSError, json.JSONDecodeError, UnicodeError):
        raise ValueError("Could not read values JSON") from None
    if not isinstance(value, dict):
        raise ValueError("Values JSON must be an object")
    return value


def _requirement_environment(entries: Sequence[str]):
    mapping: dict[str, str] = {}
    for entry in entries:
        if "=" not in entry:
            raise ValueError("Requirement environment mapping must use KEY=ENV_VAR")
        key, environment_name = entry.split("=", 1)
        if not key or not environment_name:
            raise ValueError("Requirement environment mapping must use KEY=ENV_VAR")
        mapping[key] = environment_name

    def resolve(requirement: Mapping[str, Any]) -> str:
        key = "%s:%s" % (requirement["location"], requirement["path"])
        environment_name = mapping.get(key)
        if environment_name is None or environment_name not in os.environ:
            raise ValueError("Missing External Request value for %s" % key)
        return os.environ[environment_name]

    return resolve


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Discover, query, and prepare Onchain Application Interfaces"
    )
    parser.add_argument("command", choices=("discover", "query", "prepare"))
    parser.add_argument("--chain-id", required=True, type=int)
    parser.add_argument("--adapter", required=True)
    parser.add_argument("--rpc-url")
    parser.add_argument("--allow-origin", action="append", default=[])
    parser.add_argument(
        "--requirement-env", action="append", default=[], metavar="KEY=ENV_VAR"
    )
    parser.add_argument("--max-requests", type=int, default=4)
    parser.add_argument("--max-response-bytes", type=int, default=1_048_576)
    parser.add_argument("--max-header-bytes", type=int, default=65_536)
    parser.add_argument("--timeout", type=float, default=30.0)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--id")
    selection.add_argument("--name")
    parser.add_argument("--values-file")
    parser.add_argument("--account")
    return parser


def run(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    if (
        arguments.command != "discover"
        and arguments.id is None
        and arguments.name is None
    ):
        raise ValueError("query and prepare require --id or --name")
    if arguments.command != "discover" and arguments.values_file is None:
        raise ValueError("query and prepare require --values-file (use - for stdin)")
    if arguments.command == "prepare" and arguments.account is None:
        raise ValueError("prepare requires --account")
    rpc_url = (
        arguments.rpc_url or "https://evm.stupidtech.net/v1/%d" % arguments.chain_id
    )
    client = ApplicationClient(
        rpc_url=rpc_url,
        chain_id=arguments.chain_id,
        adapter=arguments.adapter,
        allowed_origins=arguments.allow_origin,
        resolve_requirement=_requirement_environment(arguments.requirement_env),
        max_requests=arguments.max_requests,
        max_response_bytes=arguments.max_response_bytes,
        max_header_bytes=arguments.max_header_bytes,
        timeout=arguments.timeout,
    )
    discovery = client.discover()
    if arguments.command == "discover":
        result = discovery
    else:
        kind = "query" if arguments.command == "query" else "action"
        capability = client.select_capability(
            discovery=discovery,
            kind=kind,
            identifier=arguments.id,
            name=arguments.name,
        )
        values = _read_values(arguments.values_file)
        block = hex(discovery["block"])
        if arguments.command == "query":
            result = {
                "chainId": client.chain_id,
                "adapter": client.adapter,
                "rpcUrl": client.rpc.url,
                "block": discovery["block"],
                **client.query(capability=capability, values=values, block=block),
            }
        else:
            result = {
                "chainId": client.chain_id,
                "adapter": client.adapter,
                "rpcUrl": client.rpc.url,
                "block": discovery["block"],
                **client.prepare(
                    capability=capability,
                    account=arguments.account,
                    values=values,
                    block=block,
                ),
            }
    json.dump(_json_value(result), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def main() -> None:
    try:
        raise SystemExit(run())
    except KeyboardInterrupt:
        print(json.dumps({"error": "Interrupted"}), file=sys.stderr)
        raise SystemExit(130) from None
    except Exception as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        raise SystemExit(1) from None


__all__ = ["main", "run"]

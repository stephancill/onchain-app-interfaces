import json
import pathlib
import sys
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "skills/onchain-app-interfaces/scripts"))

from onchain_interfaces.abi import encode_abi, selector  # noqa: E402
from onchain_interfaces.application import ApplicationClient  # noqa: E402
from onchain_interfaces.metadata import (  # noqa: E402
    MAX_METADATA_BYTES,
    MAX_METADATA_URI_BYTES,
    resolve_contract_metadata,
)
from onchain_interfaces.rpc import RpcError  # noqa: E402

VECTORS = json.loads((ROOT / "test/vectors/contract-metadata.json").read_text("utf-8"))


class MetadataTest(unittest.TestCase):
    def test_shared_valid_vectors(self):
        for vector in VECTORS["valid"]:
            with self.subTest(vector["label"]):
                self.assertEqual(
                    resolve_contract_metadata(uri=vector["uri"], allowed_origins=set()),
                    vector["metadata"],
                )

    def test_shared_invalid_vectors(self):
        for vector in VECTORS["invalid"]:
            with (
                self.subTest(vector["label"]),
                self.assertRaisesRegex(ValueError, "Invalid application metadata"),
            ):
                resolve_contract_metadata(uri=vector["uri"], allowed_origins=set())

    def test_size_limits(self):
        for uri in (
            "x" * (MAX_METADATA_URI_BYTES + 1),
            "data:application/json,"
            + json.dumps({"name": "Example", "description": "x" * MAX_METADATA_BYTES}),
        ):
            with self.assertRaises(ValueError):
                resolve_contract_metadata(uri=uri, allowed_origins=set())

    def test_remote_authorization_precedes_network_access(self):
        with mock.patch("socket.getaddrinfo") as dns:
            with self.assertRaisesRegex(RuntimeError, "origin is not allowed"):
                resolve_contract_metadata(
                    uri="https://example.com/meta.json", allowed_origins=set()
                )
            dns.assert_not_called()

    def test_remote_resolution_and_errors(self):
        metadata = {"name": "Example", "description": "Read positions."}
        with mock.patch("onchain_interfaces.metadata.execute_https_request") as fetch:
            fetch.return_value = {"status": 200, "body": json.dumps(metadata).encode()}
            result = resolve_contract_metadata(
                uri="ipfs://QmExample/path%20name.json",
                ipfs_gateway="https://gateway.example",
                allowed_origins={"https://gateway.example"},
            )
            self.assertEqual(result, metadata)
            request = fetch.call_args.kwargs["request"]
            self.assertEqual(
                request["url"],
                "https://gateway.example/ipfs/QmExample/path%20name.json",
            )
            self.assertEqual(request["method"], "GET")
            for status in (302, 404, 500):
                fetch.return_value = {"status": status, "body": b"{}"}
                with self.assertRaisesRegex(RuntimeError, "Metadata resolution failed"):
                    resolve_contract_metadata(
                        uri="https://example.com/meta.json",
                        allowed_origins={"https://example.com"},
                    )
            fetch.return_value = {"status": 200, "body": b"{}"}
            with self.assertRaisesRegex(ValueError, "Invalid application metadata"):
                resolve_contract_metadata(
                    uri="https://example.com/meta.json",
                    allowed_origins={"https://example.com"},
                )

    def test_unsupported_uris_and_ipfs_paths(self):
        for uri in (
            "file:///etc/passwd",
            "ipfs://QmExample/../secret",
            "ipfs://QmExample/%2fsecret",
        ):
            with self.assertRaisesRegex(RuntimeError, "Metadata resolution failed"):
                resolve_contract_metadata(
                    uri=uri,
                    ipfs_gateway="https://gateway.example",
                    allowed_origins=set(),
                )
        with self.assertRaisesRegex(RuntimeError, "configured HTTPS gateway"):
            resolve_contract_metadata(uri="ipfs://QmExample", allowed_origins=set())

    def test_discovery_requires_metadata_and_a_capability_interface(self):
        client = ApplicationClient(
            rpc_url="https://rpc.example", chain_id=1, adapter="0x" + "01" * 20
        )
        uri = VECTORS["valid"][0]["uri"]
        metadata_return = encode_abi(parameters=({"type": "string"},), values=(uri,))
        empty_ids = encode_abi(parameters=({"type": "bytes32[]"},), values=([],))
        client.rpc = mock.Mock()
        client.rpc.url = "https://rpc.example"
        client.rpc.chain_id.return_value = 1
        client.rpc.block_number.return_value = 42
        client.rpc.get_code.return_value = b"\x01"

        def call(*, to, data, block):
            self.assertEqual(block, "0x2a")
            if data == selector(name="contractURI", parameters=()):
                return metadata_return
            if data == selector(name="queries", parameters=()):
                return empty_ids
            raise RpcError(method="eth_call", error={"message": "execution reverted"})

        client.rpc.eth_call.side_effect = call
        result = client.discover()
        self.assertEqual(result["metadata"], VECTORS["valid"][0]["metadata"])
        self.assertEqual(result["contractURI"], uri)
        self.assertEqual(result["unsupported"], ["Application Actions"])

        client.rpc.eth_call.side_effect = [
            metadata_return,
            RpcError(method="eth_call", error={}),
            RpcError(method="eth_call", error={}),
        ]
        with self.assertRaisesRegex(
            ValueError, "neither Application Queries nor Application Actions"
        ):
            client.discover()
        client.rpc.eth_call.side_effect = [b""]
        with self.assertRaisesRegex(ValueError, "missing or malformed"):
            client.discover()
        client.rpc.eth_call.side_effect = RuntimeError("JSON-RPC transport failed")
        with self.assertRaisesRegex(RuntimeError, "transport failed"):
            client.discover()

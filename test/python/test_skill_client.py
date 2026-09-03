import json
import pathlib
import subprocess
import sys
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "skills" / "onchain-app-interfaces" / "scripts"
sys.path.insert(0, str(SCRIPTS))

from onchain_interfaces.abi import decode_abi, selector  # noqa: E402
from onchain_interfaces.descriptor import (  # noqa: E402
    encode_descriptor_parameters,
    parse_application_descriptor,
)
from onchain_interfaces.external import _resolved_addresses  # noqa: E402
from onchain_interfaces.json_abi import transform_http_response  # noqa: E402
from onchain_interfaces.keccak import keccak256  # noqa: E402

VECTORS = json.loads(
    (ROOT / "test" / "vectors" / "application-client.json").read_text("utf-8")
)


class SkillClientTest(unittest.TestCase):
    def test_keccak_and_selectors_match_shared_vectors(self):
        self.assertEqual("0x" + keccak256(b"").hex(), VECTORS["keccak"]["empty"])
        self.assertEqual("0x" + keccak256(b"abc").hex(), VECTORS["keccak"]["abc"])
        signatures = {
            "queries": ("queries", ()),
            "actions": ("actions", ()),
            "queryDescriptor": ("queryDescriptor", ({"type": "bytes32"},)),
            "actionDescriptor": ("actionDescriptor", ({"type": "bytes32"},)),
            "query": ("query", ({"type": "bytes32"}, {"type": "bytes"})),
            "prepare": (
                "prepare",
                ({"type": "bytes32"}, {"type": "address"}, {"type": "bytes"}),
            ),
        }
        for name, (function_name, parameters) in signatures.items():
            self.assertEqual(
                "0x" + selector(name=function_name, parameters=parameters).hex(),
                VECTORS["selectors"][name],
            )

    def test_descriptor_encoding_matches_shared_vector(self):
        descriptor = parse_application_descriptor(json.dumps(VECTORS["descriptor"]))
        encoded = encode_descriptor_parameters(
            descriptor=descriptor, values=VECTORS["values"]
        )
        self.assertEqual("0x" + encoded.hex(), VECTORS["encodedParameters"])

    def test_nested_prepared_action_decodes(self):
        parameters = (
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
        decoded = decode_abi(
            parameters=parameters, data=VECTORS["preparedAction"], named=True
        )["preparedAction"]
        self.assertEqual(decoded["validUntil"], 99)
        self.assertEqual(decoded["calls"][0]["value"], 42)
        self.assertEqual(decoded["calls"][0]["data"], b"\x12\x34")

    def test_json_abi_projection_hashes_raw_body(self):
        body = b'{"data":{"amount":"42"}}'
        transformed = transform_http_response(
            response={
                "status": 200,
                "headers": [],
                "rawBodyHash": b"",
                "bodyEncoding": "RAW",
                "body": body,
            },
            transform={
                "kind": "JSON_ABI",
                "statusFrom": 200,
                "statusTo": 299,
                "nodes": [
                    {
                        "nodeType": "UINT256_DECIMAL",
                        "pointer": "/data/amount",
                        "childCount": 0,
                        "maxItems": 0,
                    }
                ],
            },
        )
        self.assertEqual(transformed["rawBodyHash"], keccak256(body))
        self.assertEqual(
            decode_abi(parameters=({"type": "uint256"},), data=transformed["body"])[0],
            42,
        )

    def test_dns_policy_rejects_mixed_public_private_answers(self):
        answers = [
            (2, 1, 6, "", ("93.184.216.34", 443)),
            (2, 1, 6, "", ("127.0.0.1", 443)),
        ]
        with mock.patch("socket.getaddrinfo", return_value=answers):
            with self.assertRaisesRegex(ValueError, "prohibited address"):
                _resolved_addresses(hostname="example.com", port=443)

    def test_cli_runs_without_repository_package_resolution(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "adapter.py"), "--help"],
            cwd="/",
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("discover", result.stdout)


if __name__ == "__main__":
    unittest.main()

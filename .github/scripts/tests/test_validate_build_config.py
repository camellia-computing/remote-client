from __future__ import annotations

import base64
import importlib.util
from pathlib import Path
import unittest


SCRIPT_PATH = Path(__file__).parents[1] / "validate_build_config.py"
SPEC = importlib.util.spec_from_file_location("validate_build_config", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class ValidateBuildConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.valid = {
            "RS_PUB_KEY": base64.b64encode(bytes(range(32))).decode("ascii"),
            "RENDEZVOUS_SERVERS": (
                "rs1.example.com:21116,[2001:db8::1]:21116"
            ),
            "API_SERVER": "https://api.example.com/v1",
        }

    def test_valid_production_configuration(self) -> None:
        VALIDATOR.validate_environment(self.valid)

    def test_public_key_is_required(self) -> None:
        with self.assertRaisesRegex(
            VALIDATOR.ConfigurationError, "RS_PUB_KEY is required"
        ):
            VALIDATOR.validate_environment({**self.valid, "RS_PUB_KEY": ""})

    def test_public_key_must_be_canonical_base64_with_32_bytes(self) -> None:
        for value in (
            "not-base64",
            base64.b64encode(b"short").decode("ascii"),
            base64.b64encode(bytes(32)).decode("ascii"),
            f" {self.valid['RS_PUB_KEY']}",
            self.valid["RS_PUB_KEY"].rstrip("="),
        ):
            with self.subTest(value=value), self.assertRaises(
                VALIDATOR.ConfigurationError
            ):
                VALIDATOR.validate_environment(
                    {**self.valid, "RS_PUB_KEY": value}
                )

    def test_rendezvous_list_rejects_malformed_entries(self) -> None:
        for value in (
            "",
            "rs1.example.com,,rs2.example.com",
            "rs1,rs1",
            "https://rs1.example.com",
            "rs1.example.com:not-a-port",
            "rs1.example.com:",
            "rs1.example.com:0",
            "999.999.999.999",
            "2001:db8::1",
            "[2001:db8::1",
            "[127.0.0.1]:21116",
        ):
            with self.subTest(value=value), self.assertRaises(
                VALIDATOR.ConfigurationError
            ):
                VALIDATOR.validate_environment(
                    {**self.valid, "RENDEZVOUS_SERVERS": value}
                )

    def test_api_server_requires_clean_https_origin(self) -> None:
        for value in (
            "",
            "http://api.example.com",
            "https://user@example.com",
            "https://api.example.com?debug=1",
            "https://api.example.com:invalid",
            "https://api_example.com",
            "https://999.999.999.999",
            "https://api.example.com:0",
            "https://[2001:db8::1",
        ):
            with self.subTest(value=value), self.assertRaises(
                VALIDATOR.ConfigurationError
            ):
                VALIDATOR.validate_environment({**self.valid, "API_SERVER": value})


if __name__ == "__main__":
    unittest.main()

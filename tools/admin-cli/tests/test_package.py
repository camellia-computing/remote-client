"""Exercise the installed entry point, not a copied source-script tree."""

import subprocess
import sys
import unittest


class PackageTests(unittest.TestCase):
    def test_every_tool_has_help_and_a_shared_deadline_without_network(self):
        tools = (
            "users",
            "devices",
            "device-groups",
            "strategies",
            "address-books",
            "audits",
            "operations",
        )
        for tool in tools:
            with self.subTest(tool=tool):
                result = subprocess.run(
                    [sys.executable, "-m", "camellia_remote_admin", tool, "--help"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--deadline", result.stdout)
                self.assertIn("camellia-remote-admin " + tool, result.stdout)

    def test_missing_dependency_has_installation_guidance_without_traceback(self):
        code = """
import importlib.abc
import sys
class MissingRequests(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname == "requests":
            raise ModuleNotFoundError("missing request library", name=fullname)
sys.meta_path.insert(0, MissingRequests())
from camellia_remote_admin.__main__ import main
main(["users", "--help"])
"""
        result = subprocess.run(
            [sys.executable, "-c", code],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("uv sync --locked", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_removed_providerless_tool_is_not_a_successful_no_op(self):
        result = subprocess.run(
            [sys.executable, "-m", "camellia_remote_admin", "user-groups"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid choice", result.stderr)


if __name__ == "__main__":
    unittest.main()

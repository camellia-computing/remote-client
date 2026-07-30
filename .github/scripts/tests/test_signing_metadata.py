import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "signing_metadata.py"


class SigningMetadataTests(unittest.TestCase):
    def run_script(self, *arguments: str, expect_success: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )
        if expect_success and result.returncode != 0:
            self.fail(result.stderr)
        if not expect_success and result.returncode == 0:
            self.fail("command unexpectedly succeeded")
        return result

    def test_write_and_aggregate_unsigned_resigning_input(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assets = root / "assets"
            assets.mkdir()
            (assets / "client-unsigned.apk").write_bytes(b"apk")
            sidecar = assets / "native-signing-android-arm64.json"
            self.run_script(
                "write",
                "--output",
                str(sidecar),
                "--artifact-directory",
                str(assets),
                "--platform",
                "android",
                "--architecture",
                "arm64",
                "--native-signing",
                "unsigned",
                "--distribution-trust",
                "none",
                "--delivery",
                "re-signing-input",
            )

            manifest = assets / "versions.json"
            manifest.write_text('{"version":"1.2.3"}\n', encoding="utf-8")
            report = assets / "NATIVE-SIGNING.md"
            self.run_script(
                "aggregate",
                "--asset-directory",
                str(assets),
                "--manifest",
                str(manifest),
                "--report",
                str(report),
            )

            result = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(result["native_artifacts"][0]["native_signing"], "unsigned")
            self.assertIn("re-signing-input", report.read_text(encoding="utf-8"))

    def test_notarized_requires_public_trust(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "client.dmg").write_bytes(b"dmg")
            self.run_script(
                "write",
                "--output",
                str(root / "native-signing-macos.json"),
                "--artifact-directory",
                str(root),
                "--platform",
                "macos",
                "--architecture",
                "universal",
                "--native-signing",
                "notarized",
                "--distribution-trust",
                "private-trust",
                "--identity",
                "Example",
                "--delivery",
                "installable",
                expect_success=False,
            )

    def test_duplicate_artifact_claim_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "client.zip").write_bytes(b"zip")
            record = {
                "schema_version": 1,
                "platform": "windows",
                "architecture": "x64",
                "native_signing": "unsigned",
                "distribution_trust": "none",
                "identity": None,
                "artifact_signing": "none",
                "artifact_signing_identity": None,
                "delivery": "installable",
                "artifacts": ["client.zip"],
            }
            for suffix in ("one", "two"):
                (root / f"native-signing-{suffix}.json").write_text(
                    json.dumps(record), encoding="utf-8"
                )
            manifest = root / "versions.json"
            manifest.write_text('{"version":"1.2.3"}\n', encoding="utf-8")
            self.run_script(
                "aggregate",
                "--asset-directory",
                str(root),
                "--manifest",
                str(manifest),
                "--report",
                str(root / "report.md"),
                expect_success=False,
            )

    def test_unclaimed_artifact_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "client.zip").write_bytes(b"zip")
            (root / "unexpected.bin").write_bytes(b"unexpected")
            record = {
                "schema_version": 1,
                "platform": "windows",
                "architecture": "x64",
                "native_signing": "unsigned",
                "distribution_trust": "none",
                "identity": None,
                "artifact_signing": "none",
                "artifact_signing_identity": None,
                "delivery": "installable",
                "artifacts": ["client.zip"],
            }
            (root / "native-signing-windows-x64.json").write_text(
                json.dumps(record), encoding="utf-8"
            )
            manifest = root / "versions.json"
            manifest.write_text('{"version":"1.2.3"}\n', encoding="utf-8")
            self.run_script(
                "aggregate",
                "--asset-directory",
                str(root),
                "--manifest",
                str(manifest),
                "--report",
                str(root / "report.md"),
                expect_success=False,
            )


if __name__ == "__main__":
    unittest.main()

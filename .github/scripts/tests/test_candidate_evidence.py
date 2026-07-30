import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "candidate_evidence.py"
WORKFLOW = Path(__file__).parents[2] / "workflows" / "release.yml"
SOURCE_COMMIT = "1" * 40
PROTOCOL_COMMIT = "2" * 40
FLUTTER_REVISION = "3" * 40


class CandidateEvidenceTests(unittest.TestCase):
    def run_script(
        self, *arguments: str, expect_success: bool = True
    ) -> subprocess.CompletedProcess:
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

    def assemble(self, source: Path, output: Path, *platforms: str) -> None:
        arguments = [
            "assemble",
            "--input-directory",
            str(source),
            "--output-directory",
            str(output),
            "--version",
            "1.2.3",
            "--app-version",
            "1.2.3+7",
            "--build-number",
            "7",
            "--tag",
            "v1.2.3",
            "--source-commit",
            SOURCE_COMMIT,
            "--protocol-commit",
            PROTOCOL_COMMIT,
            "--verified-ci-run-id",
            "41",
            "--source-date-epoch",
            "1700000000",
            "--candidate-run-id",
            "42",
            "--candidate-run-attempt",
            "1",
            "--repository",
            "camellia-computing/remote-client",
            "--workflow-ref",
            "camellia-computing/remote-client/.github/workflows/release.yml@refs/heads/main",
            "--publication-requested",
            "false",
            "--rust-toolchain",
            "1.97.1",
            "--flutter-version",
            "3.44.5",
            "--flutter-revision",
            FLUTTER_REVISION,
            "--node-version",
            "24.18.0",
            "--android-ndk-version",
            "28.2.13676358",
        ]
        for platform in platforms:
            arguments.extend(["--selected-platform", platform])
        self.run_script(*arguments)

    @staticmethod
    def write_complete_evidence(output: Path) -> None:
        manifest = json.loads((output / "versions.json").read_text(encoding="utf-8"))
        manifest["native_artifacts"] = [
            {
                "platform": "windows",
                "architecture": "x64",
            }
        ]
        (output / "versions.json").write_text(
            json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8"
        )
        (output / "NATIVE-SIGNING.md").write_text("# Native signing\n", encoding="utf-8")
        (output / "candidate.spdx.json").write_text(
            '{"spdxVersion":"SPDX-2.3"}\n', encoding="utf-8"
        )
        (output / "candidate.provenance.intoto.jsonl").write_text(
            '{"dsseEnvelope":{}}\n', encoding="utf-8"
        )

    def test_assemble_checksum_and_verify_complete_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "inputs"
            artifact = source / "camellia-remote-1.2.3-windows-x64-run-42-1"
            artifact.mkdir(parents=True)
            (artifact / "client.zip").write_bytes(b"client")
            (artifact / "native-signing-windows-x64.json").write_text(
                "{}\n", encoding="utf-8"
            )
            output = root / "assets"

            self.assemble(source, output, "windows-x64")
            self.write_complete_evidence(output)
            self.run_script("checksums", "--asset-directory", str(output))
            self.run_script(
                "verify",
                "--asset-directory",
                str(output),
                "--version",
                "1.2.3",
                "--source-commit",
                SOURCE_COMMIT,
            )

            manifest = json.loads((output / "versions.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["selected_platforms"], ["windows-x64"])
            self.assertEqual(manifest["candidate_run_id"], 42)
            checksum_lines = (output / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
            self.assertEqual(checksum_lines, sorted(checksum_lines, key=lambda line: line[66:]))

    def test_missing_selected_artifact_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "inputs"
            source.mkdir()
            self.run_script(
                "assemble",
                "--input-directory",
                str(source),
                "--output-directory",
                str(root / "assets"),
                "--version",
                "1.2.3",
                "--app-version",
                "1.2.3+7",
                "--build-number",
                "7",
                "--tag",
                "v1.2.3",
                "--source-commit",
                SOURCE_COMMIT,
                "--protocol-commit",
                PROTOCOL_COMMIT,
                "--verified-ci-run-id",
                "41",
                "--source-date-epoch",
                "1700000000",
                "--candidate-run-id",
                "42",
                "--candidate-run-attempt",
                "1",
                "--repository",
                "camellia-computing/remote-client",
                "--workflow-ref",
                "workflow@main",
                "--publication-requested",
                "false",
                "--rust-toolchain",
                "1.97.1",
                "--flutter-version",
                "3.44.5",
                "--flutter-revision",
                FLUTTER_REVISION,
                "--node-version",
                "24.18.0",
                "--android-ndk-version",
                "28.2.13676358",
                "--selected-platform",
                "windows-x64",
                expect_success=False,
            )

    def test_duplicate_flat_filename_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "inputs"
            for suffix in ("windows-x64", "web"):
                artifact = source / f"camellia-remote-1.2.3-{suffix}-run-42-1"
                artifact.mkdir(parents=True)
                (artifact / "duplicate.bin").write_bytes(suffix.encode())
            self.run_script(
                *self._assemble_arguments(source, root / "assets", "windows-x64", "web"),
                expect_success=False,
            )

    def _assemble_arguments(
        self, source: Path, output: Path, *platforms: str
    ) -> list[str]:
        arguments = [
            "assemble",
            "--input-directory",
            str(source),
            "--output-directory",
            str(output),
            "--version",
            "1.2.3",
            "--app-version",
            "1.2.3+7",
            "--build-number",
            "7",
            "--tag",
            "v1.2.3",
            "--source-commit",
            SOURCE_COMMIT,
            "--protocol-commit",
            PROTOCOL_COMMIT,
            "--verified-ci-run-id",
            "41",
            "--source-date-epoch",
            "1700000000",
            "--candidate-run-id",
            "42",
            "--candidate-run-attempt",
            "1",
            "--repository",
            "camellia-computing/remote-client",
            "--workflow-ref",
            "workflow@main",
            "--publication-requested",
            "false",
            "--rust-toolchain",
            "1.97.1",
            "--flutter-version",
            "3.44.5",
            "--flutter-revision",
            FLUTTER_REVISION,
            "--node-version",
            "24.18.0",
            "--android-ndk-version",
            "28.2.13676358",
        ]
        for platform in platforms:
            arguments.extend(["--selected-platform", platform])
        return arguments

    def test_tampered_asset_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "inputs"
            artifact = source / "camellia-remote-1.2.3-windows-x64-run-42-1"
            artifact.mkdir(parents=True)
            (artifact / "client.zip").write_bytes(b"client")
            (artifact / "native-signing-windows-x64.json").write_text(
                "{}\n", encoding="utf-8"
            )
            output = root / "assets"
            self.assemble(source, output, "windows-x64")
            self.write_complete_evidence(output)
            self.run_script("checksums", "--asset-directory", str(output))
            (output / "client.zip").write_bytes(b"tampered")
            self.run_script(
                "verify",
                "--asset-directory",
                str(output),
                "--version",
                "1.2.3",
                "--source-commit",
                SOURCE_COMMIT,
                expect_success=False,
            )

    def test_release_workflow_reuses_one_exact_attempt_candidate(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("finalize_candidate:", workflow)
        self.assertIn(
            "anchore/sbom-action@e22c389904149dbc22b58101806040fa8d37a610",
            workflow,
        )
        self.assertIn("syft-version: v1.50.0", workflow)
        self.assertIn(
            "subject-checksums: ${{ runner.temp }}/release-assets/SHA256SUMS",
            workflow,
        )
        self.assertIn("gh attestation verify", workflow)
        self.assertIn("needs.finalize_candidate.result == 'success'", workflow)
        self.assertIn("Download consolidated candidate evidence", workflow)
        self.assertEqual(workflow.count("-run-${{ github.run_id }}-${{ github.run_attempt }}"), 11)


if __name__ == "__main__":
    unittest.main()

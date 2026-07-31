#!/usr/bin/env python3
"""Regression tests for formal Remote Client release evidence."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "build-client-release-evidence.py"
SPEC = importlib.util.spec_from_file_location("client_release_evidence", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load client evidence builder")
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)

COMMIT = "a" * 40
PROTOCOL = "b" * 40


class ClientReleaseEvidenceTests(unittest.TestCase):
    def populate(self, root: Path, *, omit_web: bool = False) -> None:
        (root / "client.spdx.json").write_text(
            '{"spdxVersion":"SPDX-2.3"}\n', encoding="utf-8"
        )
        (root / "client.provenance.intoto.jsonl").write_text(
            '{"verificationMaterial":{}}\n', encoding="utf-8"
        )
        specifications = [
            ("android", "arm64", "unsigned", "none", "none"),
            ("ios", "arm64", "unsigned", "none", "none"),
            ("linux", "arm64", "not-applicable", "not-applicable", "openpgp-detached"),
            ("linux", "x64", "not-applicable", "not-applicable", "openpgp-detached"),
            ("macos", "universal", "ad-hoc", "none", "none"),
            ("windows", "arm64", "unsigned", "none", "none"),
            ("windows", "x64", "unsigned", "none", "none"),
        ]
        if not omit_web:
            specifications.append(
                ("web", "any", "not-applicable", "not-applicable", "none")
            )
        records = []
        for platform, architecture, native, trust, artifact_signing in specifications:
            product = f"client-{platform}-{architecture}.zip"
            (root / product).write_bytes(b"product")
            artifacts = [product]
            if artifact_signing == "openpgp-detached":
                signature = f"{product}.asc"
                (root / signature).write_bytes(b"signature")
                artifacts.append(signature)
            record = {
                "schema_version": 1,
                "platform": platform,
                "architecture": architecture,
                "native_signing": native,
                "distribution_trust": trust,
                "identity": None,
                "artifact_signing": artifact_signing,
                "artifact_signing_identity": None,
                "delivery": (
                    "re-signing-input"
                    if platform in {"android", "ios"}
                    else "deployment-artifact"
                    if platform == "web"
                    else "installable"
                ),
                "artifacts": artifacts,
            }
            sidecar = root / f"native-signing-{platform}-{architecture}.json"
            sidecar.write_text(json.dumps(record) + "\n", encoding="utf-8")
            records.append(record)
        manifest = {
            "schema_version": 1,
            "version": "1.2.3",
            "tag": "v1.2.3",
            "source_commit": COMMIT,
            "verified_ci_run_id": 42,
            "publication_requested": True,
            "camellia_remote_protocol_commit": PROTOCOL,
            "native_artifacts": sorted(
                records, key=lambda item: (item["platform"], item["architecture"])
            ),
        }
        (root / "versions.json").write_text(
            json.dumps(manifest) + "\n", encoding="utf-8"
        )

    @staticmethod
    def args(root: Path):
        return builder.parser().parse_args(
            [
                "--asset-directory",
                str(root),
                "--version",
                "1.2.3",
                "--commit",
                COMMIT,
                "--validation-run-id",
                "42",
                "--generated-at",
                "2026-07-31T00:00:00Z",
                "--output",
                str(root / "release-evidence.json"),
            ]
        )

    def test_builds_complete_cross_platform_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.populate(root)
            value = builder.build(self.args(root))
            self.assertEqual(value["repository"], "remote-client")
            self.assertEqual(len(value["files"]), 8)
            web = next(
                item for item in value["files"] if item["platform"] == "web"
            )
            self.assertEqual(web["architecture"], "universal")
            self.assertEqual(
                web["signing"]["category"], "not-applicable"
            )
            linux = next(
                item for item in value["files"] if item["platform"] == "linux"
            )
            self.assertEqual(linux["signing"]["category"], "private-trust")

    def test_rejects_incomplete_platform_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.populate(root, omit_web=True)
            with self.assertRaisesRegex(ValueError, "incomplete"):
                builder.build(self.args(root))

    def test_timestamp_state_follows_native_verified_trust(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = {
                "platform": "macos",
                "native_signing": "signed",
                "distribution_trust": "public-trust",
                "artifact_signing": "none",
            }
            evidence = builder.signing_evidence(
                record,
                product="client.dmg",
                sidecar="native-signing-macos-universal.json",
                directory=root,
            )
            self.assertEqual(evidence["timestamp"], "verified")

            record["distribution_trust"] = "private-trust"
            evidence = builder.signing_evidence(
                record,
                product="client.dmg",
                sidecar="native-signing-macos-universal.json",
                directory=root,
            )
            self.assertEqual(evidence["timestamp"], "missing")


if __name__ == "__main__":
    unittest.main()

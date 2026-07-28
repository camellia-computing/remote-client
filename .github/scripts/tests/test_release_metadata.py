from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT_PATH = Path(__file__).parents[1] / "release_metadata.py"
SPEC = importlib.util.spec_from_file_location("release_metadata", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
METADATA = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = METADATA
SPEC.loader.exec_module(METADATA)


def write_metadata(
    root: Path,
    *,
    manifest: str,
    locked: str,
    flutter: str,
) -> None:
    (root / "Cargo.toml").write_text(
        f'[package]\nname = "camellia-remote"\nversion = "{manifest}"\n',
        encoding="utf-8",
    )
    (root / "Cargo.lock").write_text(
        "version = 4\n\n"
        "[[package]]\n"
        'name = "camellia-remote"\n'
        f'version = "{locked}"\n',
        encoding="utf-8",
    )
    (root / "flutter").mkdir()
    (root / "flutter" / "pubspec.yaml").write_text(
        f"name: camellia_remote_app\nversion: {flutter}\n",
        encoding="utf-8",
    )


class ReleaseMetadataTests(unittest.TestCase):
    def test_accepts_consistent_stable_version_and_explicit_build_number(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_metadata(
                root,
                manifest="1.2.3",
                locked="1.2.3",
                flutter="1.2.3+45",
            )

            metadata = METADATA.load_metadata(root)

            self.assertEqual(metadata.version, "1.2.3")
            self.assertEqual(metadata.app_version, "1.2.3+45")
            self.assertEqual(metadata.build_number, "45")
            self.assertEqual(metadata.tag, "v1.2.3")

    def test_rejects_mismatched_or_ambiguous_versions(self) -> None:
        cases = (
            ("1.2.3", "1.2.2", "1.2.3+45"),
            ("1.2.3", "1.2.3", "1.2.2+45"),
            ("1.2.3", "1.2.3", "1.2.3+0"),
            ("1.2.3-rc.1", "1.2.3-rc.1", "1.2.3-rc.1+45"),
        )
        for manifest, locked, flutter in cases:
            with self.subTest(manifest=manifest, locked=locked, flutter=flutter):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    write_metadata(
                        root,
                        manifest=manifest,
                        locked=locked,
                        flutter=flutter,
                    )
                    with self.assertRaises(METADATA.MetadataError):
                        METADATA.load_metadata(root)


if __name__ == "__main__":
    unittest.main()

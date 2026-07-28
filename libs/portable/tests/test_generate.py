from __future__ import annotations

from hashlib import sha256
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT_PATH = Path(__file__).parents[1] / "generate.py"
SPEC = importlib.util.spec_from_file_location("portable_generate", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
GENERATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GENERATOR
SPEC.loader.exec_module(GENERATOR)


def deterministic_compressor(content: bytes, *, quality: int) -> bytes:
    return bytes([quality]) + content[::-1]


class PortableGeneratorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_archive_and_metadata_are_deterministic(self) -> None:
        (self.source / "camellia-remote.exe").write_bytes(b"executable")
        (self.source / "z.txt").write_bytes(b"last")
        nested = self.source / "assets"
        nested.mkdir()
        (nested / "a.txt").write_bytes(b"first")

        source = GENERATOR.validate_source_folder(self.source)
        first_entries = GENERATOR.collect_files(
            source, 7, deterministic_compressor
        )
        second_entries = GENERATOR.collect_files(
            source, 7, deterministic_compressor
        )
        self.assertEqual(first_entries, second_entries)
        self.assertEqual(
            [entry.path for entry in first_entries],
            ["camellia-remote.exe", "z.txt", "assets/a.txt"],
        )

        executable = GENERATOR.resolve_executable(source, "camellia-remote.exe")
        first_output = GENERATOR.validate_output_folder(
            self.root / "output-a", source
        )
        second_output = GENERATOR.validate_output_folder(
            self.root / "output-b", source
        )
        first_archive, first_digest = GENERATOR.write_package(
            first_entries, first_output, executable
        )
        second_archive, second_digest = GENERATOR.write_package(
            second_entries, second_output, executable
        )
        self.assertEqual(first_archive.read_bytes(), second_archive.read_bytes())
        self.assertEqual(first_digest, second_digest)
        self.assertEqual(first_digest, sha256(first_archive.read_bytes()).hexdigest())

        metadata = GENERATOR.write_app_metadata(first_output, first_digest)
        self.assertEqual(
            metadata.read_text(encoding="utf-8"),
            f'package_sha256 = "{first_digest}"\n',
        )

    def test_rejects_empty_sources_and_nested_outputs(self) -> None:
        source = GENERATOR.validate_source_folder(self.source)
        with self.assertRaisesRegex(ValueError, "does not contain any files"):
            GENERATOR.collect_files(source, 11, deterministic_compressor)
        with self.assertRaisesRegex(ValueError, "must not be inside"):
            GENERATOR.validate_output_folder(self.source / "output", source)

    def test_executable_must_be_a_regular_file_inside_source(self) -> None:
        executable = self.source / "camellia-remote.exe"
        executable.write_bytes(b"executable")
        outside = self.root / "outside.exe"
        outside.write_bytes(b"outside")
        source = GENERATOR.validate_source_folder(self.source)

        self.assertEqual(
            GENERATOR.resolve_executable(source, "camellia-remote.exe"),
            "camellia-remote.exe",
        )
        with self.assertRaisesRegex(ValueError, "inside the source folder"):
            GENERATOR.resolve_executable(source, outside)
        with self.assertRaisesRegex(ValueError, "not a regular file"):
            GENERATOR.resolve_executable(source, ".")

    def test_rejects_symbolic_links(self) -> None:
        target = self.source / "target.txt"
        target.write_text("payload", encoding="utf-8")
        link = self.source / "link.txt"
        try:
            link.symlink_to(target)
        except (NotImplementedError, OSError) as error:
            self.skipTest(f"symbolic links are unavailable: {error}")

        source = GENERATOR.validate_source_folder(self.source)
        with self.assertRaisesRegex(ValueError, "symbolic-link file"):
            GENERATOR.collect_files(source, 11, deterministic_compressor)
        with self.assertRaisesRegex(ValueError, "must not be a symbolic link"):
            GENERATOR.resolve_executable(source, "link.txt")


if __name__ == "__main__":
    unittest.main()

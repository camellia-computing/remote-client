import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "normalize-generated-bridge.py"
SPEC = importlib.util.spec_from_file_location("normalize_generated_bridge", MODULE_PATH)
normalizer = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(normalizer)


class NormalizeGeneratedBridgeTests(unittest.TestCase):
    def test_normalizes_tree_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            facade = root / "facade.dart"
            generated = root / "generated"
            generated.mkdir()
            nested = generated / "bridge.dart"
            ignored = generated / "README.md"
            facade.write_bytes(b"first  \r\nsecond\t\r\n")
            nested.write_text("nested  \n\n", encoding="utf-8")
            ignored.write_text("leave me  \n", encoding="utf-8")

            self.assertEqual(normalizer.normalize((facade, generated)), (2, 2))
            self.assertEqual(facade.read_bytes(), b"first\nsecond\n")
            self.assertEqual(nested.read_bytes(), b"nested\n\n")
            self.assertEqual(ignored.read_text(encoding="utf-8"), "leave me  \n")
            self.assertEqual(normalizer.normalize((facade, generated)), (2, 0))

    def test_rejects_missing_or_non_dart_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(FileNotFoundError):
                normalizer.dart_files((root / "missing",))
            text = root / "not-dart.txt"
            text.write_text("text", encoding="utf-8")
            with self.assertRaises(ValueError):
                normalizer.dart_files((text,))

    def test_rejects_symbolic_link_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.dart"
            target.write_text("void main() {}\n", encoding="utf-8")
            link = root / "link.dart"
            link.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "symbolic-link"):
                normalizer.dart_files((link,))


if __name__ == "__main__":
    unittest.main()

import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[3] / "res" / "lang.py"
SPEC = importlib.util.spec_from_file_location("language_maintenance", MODULE_PATH)
language = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(language)


class LanguageMaintenanceTests(unittest.TestCase):
    def test_language_names_cannot_escape_the_translation_directory(self) -> None:
        for invalid in ["../en", "nested/en", "", "en.csv"]:
            with self.assertRaises(ValueError):
                language.language_path(invalid, ".rs")

    def test_rust_strings_are_escaped(self) -> None:
        self.assertEqual(
            language.rust_string('path\\name "quoted"\n'),
            'path\\\\name \\"quoted\\"\\n',
        )


if __name__ == "__main__":
    unittest.main()

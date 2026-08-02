import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[3] / "res" / "lang.py"
SPEC = importlib.util.spec_from_file_location("language_maintenance", MODULE_PATH)
language = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(language)


class LanguageMaintenanceTests(unittest.TestCase):
    def test_only_supported_translation_tables_are_checked_in(self) -> None:
        self.assertEqual(
            set(language.LANGUAGE_SOURCES),
            {"en", "cn", "tw", "template"},
        )

    def test_chinese_tables_match_the_template_and_are_complete(self) -> None:
        template_keys = set(language.get_lang("template"))
        for locale in ("cn", "tw"):
            translations = language.get_lang(locale)
            self.assertEqual(set(translations), template_keys)
            self.assertFalse(
                [key for key, value in translations.items() if not value],
                f"{locale} contains empty translations",
            )

    def test_language_names_cannot_escape_the_translation_directory(self) -> None:
        for invalid in ["../en", "nested/en", "", "en.csv", "not_a_language"]:
            with self.assertRaises(ValueError):
                language.language_path(invalid, ".rs")
        with self.assertRaisesRegex(ValueError, "unsupported language file suffix"):
            language.language_path("en", ".txt")

    def test_rust_strings_are_escaped(self) -> None:
        self.assertEqual(
            language.rust_string('path\\name "quoted"\n'),
            'path\\\\name \\"quoted\\"\\n',
        )


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Maintain the checked-in Rust translation tables."""

from __future__ import annotations

import csv
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANG_DIRECTORY = ROOT / "src" / "lang"
LANGUAGE_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,31}$")
LANGUAGE_SOURCES = {
    path.stem: path
    for path in LANG_DIRECTORY.glob("*.rs")
    if path.is_file() and not path.is_symlink()
}


def language_path(language: str, suffix: str) -> Path:
    if LANGUAGE_NAME.fullmatch(language) is None:
        raise ValueError(f"invalid language name: {language!r}")
    source = LANGUAGE_SOURCES.get(language)
    if source is None:
        raise ValueError(f"unknown checked-in language: {language!r}")
    if suffix == ".rs":
        return source
    if suffix == ".csv":
        return source.with_suffix(".csv")
    raise ValueError(f"unsupported language file suffix: {suffix!r}")


def get_lang(language: str) -> dict[str, str]:
    translations: dict[str, str] = {}
    with language_path(language, ".rs").open(encoding="utf-8") as source:
        for line in source:
            stripped = line.strip()
            if stripped.startswith('("'):
                key, value = line_split(stripped)
                translations[key] = value
    return translations


def line_split(line: str) -> tuple[str, str]:
    tokens = line.split('", "')
    if len(tokens) != 2:
        raise ValueError(f"unsupported translation row: {line}")
    key = tokens[0][tokens[0].find('"') + 1 :]
    value = tokens[1][: tokens[1].rfind('"')]
    return key, value


def expand() -> None:
    template_path = language_path("template", ".rs")
    template = template_path.read_text(encoding="utf-8").splitlines(keepends=True)
    for source_path in sorted(LANG_DIRECTORY.glob("*.rs")):
        language = source_path.stem
        if language in {"en", "template"}:
            continue
        print(language)
        translations = get_lang(language)
        rendered: list[str] = []
        for line in template:
            stripped = line.strip()
            if stripped.startswith('("'):
                key, value = line_split(stripped)
                replacement = translations.get(key, "")
                line = line.replace(f'"{value}"', f'"{replacement}"')
            rendered.append(line)
        source_path.write_text("".join(rendered), encoding="utf-8")


def to_csv() -> None:
    for source_path in sorted(LANG_DIRECTORY.glob("*.rs")):
        csv_path = language_path(source_path.stem, ".csv")
        with (
            source_path.open(encoding="utf-8") as source,
            csv_path.open("w", encoding="utf-8", newline="") as destination,
        ):
            writer = csv.writer(destination)
            for line in source:
                stripped = line.strip()
                if stripped.startswith('("'):
                    writer.writerow(line_split(stripped))


def rust_string(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )


def to_rs(language: str) -> None:
    source_path = language_path(language, ".rs")
    csv_path = language_path(language, ".csv")
    with (
        csv_path.open(encoding="utf-8", newline="") as csv_file,
        source_path.open("w", encoding="utf-8", newline="\n") as destination,
    ):
        destination.write(
            """lazy_static::lazy_static! {
pub static ref T: std::collections::HashMap<&'static str, &'static str> =
    [
"""
        )
        for row in csv.reader(csv_file):
            if len(row) != 2:
                raise ValueError(
                    "each translation CSV row must contain exactly two fields"
                )
            destination.write(
                f'        ("{rust_string(row[0])}", "{rust_string(row[1])}"),\n'
            )
        destination.write("""    ].iter().cloned().collect();
}
""")


def main(argv: list[str]) -> int:
    if not argv:
        expand()
    elif argv == ["1"]:
        to_csv()
    elif len(argv) == 1:
        to_rs(argv[0])
    else:
        raise SystemExit("usage: res/lang.py [1|LANGUAGE]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

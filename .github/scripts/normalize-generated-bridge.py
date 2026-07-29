#!/usr/bin/env python3
"""Normalize generated Dart bridge sources after their native formatters run."""

from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PATHS = (
    ROOT / "flutter/lib/generated_bridge.dart",
    ROOT / "flutter/lib/generated_bridge",
)


def dart_files(paths: Iterable[Path]) -> list[Path]:
    files: set[Path] = set()
    for path in paths:
        if path.is_file():
            if path.suffix != ".dart":
                raise ValueError(f"expected a Dart source path, found {path}")
            files.add(path)
        elif path.is_dir():
            files.update(path.rglob("*.dart"))
        else:
            raise FileNotFoundError(path)
    return sorted(files)


def normalize_file(path: Path) -> bool:
    original = path.read_text(encoding="utf-8")
    normalized = "\n".join(
        line.rstrip(" \t") for line in original.splitlines()
    )
    if normalized:
        normalized += "\n"
    if normalized == original:
        return False
    path.write_text(normalized, encoding="utf-8")
    return True


def normalize(paths: Iterable[Path]) -> tuple[int, int]:
    files = dart_files(paths)
    changed = sum(normalize_file(path) for path in files)
    return len(files), changed


def main(argv: list[str]) -> int:
    paths = [Path(value).resolve() for value in argv] if argv else list(DEFAULT_PATHS)
    total, changed = normalize(paths)
    print(f"Normalized {total} Dart bridge files ({changed} changed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

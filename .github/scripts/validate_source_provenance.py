#!/usr/bin/env python3
"""Fail closed when the recorded protocol source differs from the Git submodule."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


PROTOCOL_PATH = Path("libs/camellia_remote_protocol")
PROTOCOL_REPOSITORY = "https://github.com/camellia-computing/remote-protocol"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class ProvenanceError(ValueError):
    """Raised when source provenance is missing, malformed, or stale."""


def validate_document(document: object, actual_commit: str) -> None:
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise ProvenanceError("SOURCE_PROVENANCE.json must use schema_version 1")
    if document.get("protocol_repository") != PROTOCOL_REPOSITORY:
        raise ProvenanceError("protocol_repository is not the canonical repository")

    recorded_commit = document.get("protocol_source_commit")
    if not isinstance(recorded_commit, str) or SHA_RE.fullmatch(recorded_commit) is None:
        raise ProvenanceError("protocol_source_commit must be one full lowercase Git SHA")
    if SHA_RE.fullmatch(actual_commit) is None:
        raise ProvenanceError("protocol submodule does not resolve to one full Git SHA")
    if recorded_commit != actual_commit:
        raise ProvenanceError(
            f"protocol provenance mismatch: recorded={recorded_commit}, actual={actual_commit}"
        )


def _run_git(root: Path, arguments: list[str]) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown Git error"
        raise ProvenanceError(f"cannot resolve protocol submodule: {detail}")
    return result.stdout.strip()


def resolve_protocol_commit(root: Path) -> str:
    submodule = root / PROTOCOL_PATH
    if (submodule / ".git").exists():
        return _run_git(submodule, ["rev-parse", "HEAD"])

    entry = _run_git(root, ["ls-tree", "HEAD", "--", PROTOCOL_PATH.as_posix()])
    fields = entry.split(maxsplit=3)
    if len(fields) != 4 or fields[0] != "160000" or fields[1] != "commit":
        raise ProvenanceError("release source does not contain the protocol Git submodule")
    return fields[2]


def validate_repository(root: Path) -> None:
    root = root.resolve()
    try:
        document = json.loads((root / "SOURCE_PROVENANCE.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProvenanceError(f"cannot read SOURCE_PROVENANCE.json: {error}") from error
    validate_document(document, resolve_protocol_commit(root))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="repository root",
    )
    args = parser.parse_args(argv)
    try:
        validate_repository(args.root)
    except ProvenanceError as error:
        print(f"source provenance error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

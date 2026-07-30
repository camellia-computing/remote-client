#!/usr/bin/env python3
"""Fail closed when the recorded protocol source differs from the Git submodule."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


PROTOCOL_PATH = Path("libs/camellia_remote_protocol")
PROTOCOL_SUBMODULE = "submodule.libs/camellia_remote_protocol.url"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY_NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,100}$")


class ProvenanceError(ValueError):
    """Raised when source provenance is missing, malformed, or stale."""


def validate_document(
    document: object,
    actual_commit: str,
    actual_repository: str,
) -> None:
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise ProvenanceError("SOURCE_PROVENANCE.json must use schema_version 1")
    sibling_name = actual_repository.removeprefix("../").removesuffix(".git")
    if (
        not actual_repository.startswith("../")
        or not actual_repository.endswith(".git")
        or REPOSITORY_NAME_RE.fullmatch(sibling_name) is None
        or sibling_name in {".", ".."}
    ):
        raise ProvenanceError(
            "protocol submodule must use one portable relative sibling repository"
        )
    if document.get("protocol_repository") != actual_repository:
        raise ProvenanceError("protocol_repository does not match .gitmodules")

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


def resolve_protocol_repository(root: Path) -> str:
    repository = _run_git(
        root,
        ["config", "-f", ".gitmodules", "--get", PROTOCOL_SUBMODULE],
    )
    if not repository:
        raise ProvenanceError("release source does not define the protocol Git submodule")
    return repository


def validate_repository(root: Path) -> None:
    root = root.resolve()
    try:
        document = json.loads((root / "SOURCE_PROVENANCE.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProvenanceError(f"cannot read SOURCE_PROVENANCE.json: {error}") from error
    validate_document(
        document,
        resolve_protocol_commit(root),
        resolve_protocol_repository(root),
    )


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    try:
        validate_repository(root)
    except ProvenanceError as error:
        print(f"source provenance error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

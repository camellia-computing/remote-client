#!/usr/bin/env python3
"""Validate and expose the client's canonical release metadata."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tomllib
from dataclasses import asdict, dataclass
from pathlib import Path


SEMVER_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
SEMVER_RE = re.compile(rf"^{SEMVER_PATTERN}$")
PUBSPEC_VERSION_RE = re.compile(rf"^version:[ \t]*({SEMVER_PATTERN})\+([1-9][0-9]*)[ \t]*$", re.MULTILINE)


class MetadataError(ValueError):
    """Raised when release metadata is missing, ambiguous, or inconsistent."""


@dataclass(frozen=True)
class ReleaseMetadata:
    version: str
    app_version: str
    build_number: str
    tag: str
    major: str
    minor: str
    patch: str


def _read_toml(path: Path) -> dict:
    try:
        with path.open("rb") as file:
            return tomllib.load(file)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise MetadataError(f"cannot read {path}: {error}") from error


def _manifest_version(root: Path) -> str:
    package = _read_toml(root / "Cargo.toml").get("package")
    if not isinstance(package, dict) or package.get("name") != "camellia-remote":
        raise MetadataError("Cargo.toml must describe package camellia-remote")
    version = package.get("version")
    if not isinstance(version, str):
        raise MetadataError("Cargo.toml package.version must be a string")
    return version


def _lock_version(root: Path) -> str:
    packages = _read_toml(root / "Cargo.lock").get("package")
    if not isinstance(packages, list):
        raise MetadataError("Cargo.lock does not contain a package list")
    matches = [
        package
        for package in packages
        if isinstance(package, dict) and package.get("name") == "camellia-remote"
    ]
    if len(matches) != 1 or not isinstance(matches[0].get("version"), str):
        raise MetadataError("Cargo.lock must contain exactly one camellia-remote package")
    return matches[0]["version"]


def _pubspec_version(root: Path) -> tuple[str, str]:
    path = root / "flutter" / "pubspec.yaml"
    try:
        contents = path.read_text(encoding="utf-8")
    except OSError as error:
        raise MetadataError(f"cannot read {path}: {error}") from error
    matches = list(PUBSPEC_VERSION_RE.finditer(contents))
    if len(matches) != 1:
        raise MetadataError("flutter/pubspec.yaml must contain one stable version with a positive build number")
    return matches[0].group(1), matches[0].group(5)


def load_metadata(root: Path) -> ReleaseMetadata:
    root = root.resolve()
    manifest_version = _manifest_version(root)
    match = SEMVER_RE.fullmatch(manifest_version)
    if match is None:
        raise MetadataError("client version must be stable SemVer MAJOR.MINOR.PATCH")

    lock_version = _lock_version(root)
    flutter_version, build_number = _pubspec_version(root)
    if lock_version != manifest_version or flutter_version != manifest_version:
        raise MetadataError(
            "version mismatch: "
            f"Cargo.toml={manifest_version}, Cargo.lock={lock_version}, "
            f"flutter/pubspec.yaml={flutter_version}"
        )

    major, minor, patch = match.groups()
    return ReleaseMetadata(
        version=manifest_version,
        app_version=f"{manifest_version}+{build_number}",
        build_number=build_number,
        tag=f"v{manifest_version}",
        major=major,
        minor=minor,
        patch=patch,
    )


def _write_github_output(path: Path, metadata: ReleaseMetadata) -> None:
    with path.open("a", encoding="utf-8") as output:
        for key, value in asdict(metadata).items():
            output.write(f"{key}={value}\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="repository root (defaults to the repository containing .github/)",
    )
    parser.add_argument("--expect-tag", help="require this exact canonical v-prefixed tag")
    parser.add_argument("--github-output", action="store_true")
    args = parser.parse_args(argv)

    try:
        metadata = load_metadata(args.root)
        if args.expect_tag is not None and args.expect_tag != metadata.tag:
            raise MetadataError(f"expected tag {metadata.tag}, got {args.expect_tag}")
        if args.github_output:
            output_path = os.environ.get("GITHUB_OUTPUT")
            if not output_path:
                raise MetadataError("GITHUB_OUTPUT is required with --github-output")
            _write_github_output(Path(output_path), metadata)
    except MetadataError as error:
        print(f"release metadata error: {error}", file=sys.stderr)
        return 1

    print(json.dumps(asdict(metadata), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

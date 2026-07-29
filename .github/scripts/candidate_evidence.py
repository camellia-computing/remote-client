#!/usr/bin/env python3
"""Assemble and verify one immutable, auditable release-candidate asset set."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path
from typing import Any


PLATFORM_SUFFIXES = {
    "windows-x64": "windows-x64",
    "windows-arm64": "windows-arm64",
    "macos-universal": "macos-universal",
    "linux-x64": "linux-x64",
    "linux-arm64": "linux-arm64",
    "android-arm64": "android-arm64",
    "ios": "ios",
    "web": "web",
}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")


def require_plain_filename(name: str) -> None:
    if (
        not name
        or name in {".", "..", "SHA256SUMS"}
        or "/" in name
        or "\\" in name
        or "\n" in name
        or "\r" in name
    ):
        raise ValueError(f"unsafe candidate filename: {name!r}")


def positive_integer(value: str, label: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise ValueError(f"{label} must be an integer") from error
    if parsed <= 0:
        raise ValueError(f"{label} must be positive")
    return parsed


def require_commit(value: str, label: str) -> str:
    if not COMMIT_PATTERN.fullmatch(value):
        raise ValueError(f"{label} must be one full lowercase commit SHA")
    return value


def parse_boolean(value: str, label: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise ValueError(f"{label} must be true or false")


def selected_platforms(values: list[str]) -> list[str]:
    if not values:
        raise ValueError("at least one candidate platform must be selected")
    if len(values) != len(set(values)):
        raise ValueError("selected candidate platforms must be unique")
    unknown = sorted(set(values) - PLATFORM_SUFFIXES.keys())
    if unknown:
        raise ValueError(f"unsupported candidate platforms: {', '.join(unknown)}")
    return sorted(values)


def assemble(args: argparse.Namespace) -> None:
    source = Path(args.input_directory)
    output = Path(args.output_directory)
    platforms = selected_platforms(args.selected_platform)
    candidate_run_id = positive_integer(args.candidate_run_id, "candidate run ID")
    candidate_run_attempt = positive_integer(
        args.candidate_run_attempt, "candidate run attempt"
    )
    if not source.is_dir() or source.is_symlink():
        raise ValueError("candidate input directory is missing or unsafe")
    if output.exists():
        raise ValueError("candidate output directory must not already exist")

    expected_directories = {
        f"camellia-remote-{args.version}-{PLATFORM_SUFFIXES[platform]}"
        f"-run-{candidate_run_id}-{candidate_run_attempt}"
        for platform in platforms
    }
    input_entries = sorted(source.iterdir(), key=lambda path: path.name)
    actual_directories = {path.name for path in input_entries}
    if actual_directories != expected_directories:
        missing = sorted(expected_directories - actual_directories)
        unexpected = sorted(actual_directories - expected_directories)
        raise ValueError(
            f"candidate artifact directories do not match selection; "
            f"missing={missing}, unexpected={unexpected}"
        )

    output.mkdir()
    copied: list[str] = []
    for artifact_directory in input_entries:
        if artifact_directory.is_symlink() or not artifact_directory.is_dir():
            raise ValueError(f"candidate input is not a safe directory: {artifact_directory.name}")
        entries = sorted(artifact_directory.iterdir(), key=lambda path: path.name)
        if not entries:
            raise ValueError(f"candidate artifact is empty: {artifact_directory.name}")
        for path in entries:
            require_plain_filename(path.name)
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"candidate artifacts must be flat regular files: {path}")
            destination = output / path.name
            if destination.exists():
                raise ValueError(f"duplicate candidate filename: {path.name}")
            shutil.copyfile(path, destination)
            copied.append(path.name)

    if not copied:
        raise ValueError("no candidate files were assembled")

    manifest: dict[str, Any] = {
        "schema_version": 1,
        "version": args.version,
        "app_version": args.app_version,
        "build_number": positive_integer(args.build_number, "build number"),
        "tag": args.tag,
        "source_commit": require_commit(args.source_commit, "source commit"),
        "camellia_remote_protocol_commit": require_commit(
            args.protocol_commit, "protocol commit"
        ),
        "verified_ci_run_id": positive_integer(args.verified_ci_run_id, "CI run ID"),
        "source_date_epoch": positive_integer(args.source_date_epoch, "source date epoch"),
        "candidate_run_id": candidate_run_id,
        "candidate_run_attempt": candidate_run_attempt,
        "candidate_repository": args.repository,
        "candidate_workflow_ref": args.workflow_ref,
        "publication_requested": parse_boolean(
            args.publication_requested, "publication requested"
        ),
        "selected_platforms": platforms,
        "dependency_mode": "locked",
        "rust_toolchain": args.rust_toolchain,
        "flutter_version": args.flutter_version,
        "flutter_revision": require_commit(args.flutter_revision, "Flutter revision"),
        "node_version": args.node_version,
        "android_ndk_version": args.android_ndk_version,
    }
    (output / "versions.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def candidate_files(directory: Path) -> list[Path]:
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError("candidate asset directory is missing or unsafe")
    files: list[Path] = []
    for path in sorted(directory.iterdir(), key=lambda item: item.name):
        if path.name == "SHA256SUMS":
            continue
        require_plain_filename(path.name)
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"candidate assets must be flat regular files: {path}")
        files.append(path)
    if not files:
        raise ValueError("candidate asset directory is empty")
    return files


def write_checksums(args: argparse.Namespace) -> None:
    directory = Path(args.asset_directory)
    lines = [f"{sha256(path)}  {path.name}" for path in candidate_files(directory)]
    (directory / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")


def read_checksums(path: Path) -> dict[str, str]:
    if path.is_symlink() or not path.is_file():
        raise ValueError("SHA256SUMS is missing or unsafe")
    checksums: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if "  " not in line:
            raise ValueError(f"invalid checksum line {line_number}")
        digest, name = line.split("  ", 1)
        if not SHA256_PATTERN.fullmatch(digest):
            raise ValueError(f"invalid SHA-256 on line {line_number}")
        require_plain_filename(name)
        if name in checksums:
            raise ValueError(f"duplicate checksum entry: {name}")
        checksums[name] = digest
    if not checksums:
        raise ValueError("SHA256SUMS has no entries")
    return checksums


def require_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid JSON evidence file: {path.name}") from error


def verify(args: argparse.Namespace) -> None:
    directory = Path(args.asset_directory)
    files = candidate_files(directory)
    actual_names = {path.name for path in files}
    checksums = read_checksums(directory / "SHA256SUMS")
    if set(checksums) != actual_names:
        missing = sorted(actual_names - checksums.keys())
        unexpected = sorted(checksums.keys() - actual_names)
        raise ValueError(
            f"checksum inventory does not match candidate assets; "
            f"missing={missing}, unexpected={unexpected}"
        )
    for name, expected in checksums.items():
        actual = sha256(directory / name)
        if actual != expected:
            raise ValueError(f"candidate checksum mismatch: {name}")

    required = {"versions.json", "NATIVE-SIGNING.md"}
    missing_required = sorted(required - actual_names)
    if missing_required:
        raise ValueError(f"required candidate evidence is missing: {missing_required}")
    sidecars = sorted(name for name in actual_names if name.startswith("native-signing-"))
    if not sidecars:
        raise ValueError("candidate signing metadata is missing")

    sbom_names = sorted(name for name in actual_names if name.endswith(".spdx.json"))
    provenance_names = sorted(
        name for name in actual_names if name.endswith(".provenance.intoto.jsonl")
    )
    if len(sbom_names) != 1:
        raise ValueError("candidate must contain exactly one SPDX JSON SBOM")
    if len(provenance_names) != 1:
        raise ValueError("candidate must contain exactly one provenance bundle")

    manifest = require_json(directory / "versions.json")
    if not isinstance(manifest, dict):
        raise ValueError("candidate manifest must be a JSON object")
    if manifest.get("schema_version") != 1:
        raise ValueError("unsupported candidate manifest schema")
    if manifest.get("version") != args.version:
        raise ValueError("candidate manifest version does not match")
    if manifest.get("source_commit") != args.source_commit:
        raise ValueError("candidate manifest source commit does not match")
    if not isinstance(manifest.get("native_artifacts"), list) or not manifest["native_artifacts"]:
        raise ValueError("candidate manifest has no aggregated native signing records")
    if len(manifest["native_artifacts"]) != len(sidecars):
        raise ValueError("candidate signing sidecars do not match manifest records")

    sbom = require_json(directory / sbom_names[0])
    if not isinstance(sbom, dict):
        raise ValueError("candidate SBOM must be a JSON object")
    if not isinstance(sbom.get("spdxVersion"), str) or not sbom["spdxVersion"].startswith(
        "SPDX-"
    ):
        raise ValueError("candidate SBOM is not SPDX JSON")

    provenance_lines = (directory / provenance_names[0]).read_text(
        encoding="utf-8"
    ).splitlines()
    if not provenance_lines:
        raise ValueError("candidate provenance bundle is empty")
    for line in provenance_lines:
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError("candidate provenance bundle is not JSONL") from error
        if not isinstance(value, dict):
            raise ValueError("candidate provenance entries must be JSON objects")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)

    collect = commands.add_parser("assemble")
    collect.add_argument("--input-directory", required=True)
    collect.add_argument("--output-directory", required=True)
    collect.add_argument("--version", required=True)
    collect.add_argument("--app-version", required=True)
    collect.add_argument("--build-number", required=True)
    collect.add_argument("--tag", required=True)
    collect.add_argument("--source-commit", required=True)
    collect.add_argument("--protocol-commit", required=True)
    collect.add_argument("--verified-ci-run-id", required=True)
    collect.add_argument("--source-date-epoch", required=True)
    collect.add_argument("--candidate-run-id", required=True)
    collect.add_argument("--candidate-run-attempt", required=True)
    collect.add_argument("--repository", required=True)
    collect.add_argument("--workflow-ref", required=True)
    collect.add_argument("--publication-requested", required=True)
    collect.add_argument("--rust-toolchain", required=True)
    collect.add_argument("--flutter-version", required=True)
    collect.add_argument("--flutter-revision", required=True)
    collect.add_argument("--node-version", required=True)
    collect.add_argument("--android-ndk-version", required=True)
    collect.add_argument(
        "--selected-platform",
        action="append",
        default=[],
        choices=sorted(PLATFORM_SUFFIXES),
    )
    collect.set_defaults(handler=assemble)

    checksums = commands.add_parser("checksums")
    checksums.add_argument("--asset-directory", required=True)
    checksums.set_defaults(handler=write_checksums)

    inspect = commands.add_parser("verify")
    inspect.add_argument("--asset-directory", required=True)
    inspect.add_argument("--version", required=True)
    inspect.add_argument("--source-commit", required=True)
    inspect.set_defaults(handler=verify)
    return root


def main() -> None:
    args = parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()

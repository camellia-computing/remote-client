#!/usr/bin/env python3
"""Build organization release evidence from the frozen client candidate."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from types import ModuleType
from typing import Any


POLICY_REVISION = "2026-07-31.1"
SIGNING_REGISTRY_REVISION = "2026-07-31.1"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
PLATFORMS = {
    ("android", "arm64"),
    ("ios", "arm64"),
    ("linux", "arm64"),
    ("linux", "x64"),
    ("macos", "universal"),
    ("web", "universal"),
    ("windows", "arm64"),
    ("windows", "x64"),
}


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def load_json(path: Path, label: str) -> Any:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"{label} must be a regular file")
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=unique_object,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not valid JSON") from error


def load_validator() -> ModuleType:
    path = Path(__file__).with_name("validate-release-evidence.py")
    spec = importlib.util.spec_from_file_location(
        "release_evidence_validator", path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load release evidence validator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def evidence_file(path: Path) -> dict[str, str]:
    if not path.is_file() or path.is_symlink() or path.stat().st_size < 1:
        raise ValueError(f"evidence file must be non-empty and regular: {path}")
    return {"name": path.name, "sha256": sha256(path)}


def signing_evidence(
    record: dict[str, Any],
    *,
    product: str,
    sidecar: str,
    directory: Path,
) -> dict[str, Any]:
    platform = record["platform"]
    native = record["native_signing"]
    trust = record["distribution_trust"]
    artifact_signing = record["artifact_signing"]
    evidence: list[str] = []

    if platform == "web":
        return {
            "category": "not-applicable",
            "verification": "not-applicable",
            "verifier": "none",
            "timestamp": "not-applicable",
            "distribution": "not-applicable",
            "evidence": [],
        }

    if artifact_signing == "openpgp-detached":
        signature = f"{product}.asc"
        if not (directory / signature).is_file():
            raise ValueError(f"OpenPGP signature is missing for {product}")
        return {
            "category": "private-trust",
            "verification": "verified",
            "verifier": "openpgp",
            "timestamp": "missing",
            "distribution": "installable",
            "evidence": sorted([sidecar, signature]),
        }

    if native in {"signed", "notarized"}:
        if trust not in {"public-trust", "private-trust", "platform-key"}:
            raise ValueError(f"signed artifact has invalid trust category: {product}")
        return {
            "category": trust,
            "verification": "verified",
            "verifier": "platform-native",
            "timestamp": (
                "verified"
                if native == "notarized"
                or platform == "windows"
                or (platform == "macos" and trust == "public-trust")
                else "missing"
            ),
            "distribution": "installable",
            "evidence": [sidecar],
        }

    if native == "ad-hoc":
        return {
            "category": "ad-hoc",
            "verification": "verified",
            "verifier": "platform-native",
            "timestamp": "not-applicable",
            "distribution": "restricted",
            "evidence": [sidecar],
        }

    if native in {"unsigned", "not-applicable"}:
        return {
            "category": "unsigned",
            "verification": "not-present",
            "verifier": "none",
            "timestamp": "not-applicable",
            "distribution": (
                "re-signing-input"
                if platform in {"android", "ios"}
                else "restricted"
            ),
            "evidence": [],
        }

    raise ValueError(f"unsupported signing mode for {product}")


def build(args: argparse.Namespace) -> dict[str, Any]:
    directory = args.asset_directory
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError("asset directory must be an existing real directory")
    if not SEMVER.fullmatch(args.version):
        raise ValueError("version must be stable SemVer")
    if not COMMIT.fullmatch(args.commit):
        raise ValueError("commit must be a full lowercase SHA")
    manifest = load_json(directory / "versions.json", "candidate manifest")
    if (
        not isinstance(manifest, dict)
        or manifest.get("version") != args.version
        or manifest.get("source_commit") != args.commit
        or manifest.get("tag") != f"v{args.version}"
        or manifest.get("verified_ci_run_id") != args.validation_run_id
        or manifest.get("publication_requested") is not True
    ):
        raise ValueError("candidate manifest does not match the formal release")
    protocol_commit = manifest.get("camellia_remote_protocol_commit")
    if not isinstance(protocol_commit, str) or not COMMIT.fullmatch(protocol_commit):
        raise ValueError("candidate manifest has no exact protocol dependency")
    records = manifest.get("native_artifacts")
    if not isinstance(records, list):
        raise ValueError("candidate manifest has no native artifact records")

    sboms = sorted(directory.glob("*.spdx.json"))
    provenances = sorted(directory.glob("*.provenance.intoto.jsonl"))
    if len(sboms) != 1 or len(provenances) != 1:
        raise ValueError("candidate must have exactly one SBOM and provenance")
    sbom = evidence_file(sboms[0])
    provenance = evidence_file(provenances[0])

    identities: set[tuple[str, str]] = set()
    claimed: set[str] = set()
    files: list[dict[str, Any]] = []
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("native artifact record must be an object")
        platform = record.get("platform")
        architecture = record.get("architecture")
        if platform == "web" and architecture == "any":
            architecture = "universal"
        identity = (str(platform), str(architecture))
        if identity not in PLATFORMS or identity in identities:
            raise ValueError(f"unexpected or duplicate release platform: {identity}")
        identities.add(identity)
        sidecar = f"native-signing-{platform}-{record.get('architecture')}.json"
        if not (directory / sidecar).is_file():
            raise ValueError(f"signing sidecar is missing: {sidecar}")
        artifacts = record.get("artifacts")
        if not isinstance(artifacts, list) or not artifacts:
            raise ValueError(f"release platform has no artifacts: {identity}")
        products = [
            name
            for name in artifacts
            if isinstance(name, str) and not name.endswith(".asc")
        ]
        if not products:
            raise ValueError(f"release platform has no product files: {identity}")
        for product in products:
            if product in claimed:
                raise ValueError(f"product is claimed more than once: {product}")
            path = directory / product
            if not path.is_file() or path.is_symlink() or path.stat().st_size < 1:
                raise ValueError(f"product file is missing or unsafe: {product}")
            claimed.add(product)
            files.append(
                {
                    "name": product,
                    "sha256": sha256(path),
                    "size_bytes": path.stat().st_size,
                    "platform": platform,
                    "architecture": architecture,
                    "sbom": sbom,
                    "provenance": provenance,
                    "signing": signing_evidence(
                        record,
                        product=product,
                        sidecar=sidecar,
                        directory=directory,
                    ),
                }
            )
    if identities != PLATFORMS:
        missing = sorted(PLATFORMS - identities)
        raise ValueError(f"formal release platform set is incomplete: {missing}")

    generated_at = args.generated_at or datetime.now(timezone.utc).isoformat(
        timespec="seconds"
    ).replace("+00:00", "Z")
    value = {
        "schema_version": 1,
        "repository": "remote-client",
        "version": args.version,
        "source": {
            "commit": args.commit,
            "ref": f"refs/tags/v{args.version}",
            "validation_run_id": args.validation_run_id,
        },
        "release_kind": "formal",
        "generated_at": generated_at,
        "policy": {
            "repository_policy_revision": POLICY_REVISION,
            "signing_registry_revision": SIGNING_REGISTRY_REVISION,
            "exceptions": [],
        },
        "dependencies": [
            {
                "repository": "remote-protocol",
                "commit": protocol_commit,
                "version": None,
                "relation": "builds-from",
                "evidence": "versions.json",
            }
        ],
        "files": sorted(files, key=lambda item: item["name"]),
        "images": [],
    }
    load_validator().validate_release_evidence(value)
    return value


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--asset-directory", required=True, type=Path)
    result.add_argument("--version", required=True)
    result.add_argument("--commit", required=True)
    result.add_argument("--validation-run-id", required=True, type=int)
    result.add_argument("--generated-at")
    result.add_argument("--output", required=True, type=Path)
    return result


def main() -> None:
    args = parser().parse_args()
    value = build(args)
    if args.output.parent.resolve() != args.asset_directory.resolve():
        raise ValueError("release evidence output must be inside the asset directory")
    args.output.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()

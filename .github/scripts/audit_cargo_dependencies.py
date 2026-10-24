#!/usr/bin/env python3
"""Fail on Rust vulnerabilities, warning growth, or expired risk exceptions."""

from __future__ import annotations

import argparse
from datetime import date
import json
from pathlib import Path
import subprocess
import sys
import tomllib
from typing import Any


POLICY_KEYS = {"schema_version", "reviewed_on", "exception_groups"}
GROUP_KEYS = {
    "id",
    "owner",
    "expires_on",
    "reason",
    "exit_condition",
    "warnings",
}
WARNING_KEYS = {"category", "advisory_id", "package", "version"}
WarningIdentity = tuple[str, str | None, str, str]


class PolicyError(ValueError):
    """The reviewed warning budget is malformed or expired."""


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        raise PolicyError(
            f"{label} keys differ: expected {sorted(expected)}, got {sorted(actual)}"
        )


def _nonempty_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or value != value.strip():
        raise PolicyError(f"{label} must be a non-empty trimmed string")
    return value


def _policy_identity(value: Any, label: str) -> WarningIdentity:
    if not isinstance(value, dict):
        raise PolicyError(f"{label} must be an object")
    _exact_keys(value, WARNING_KEYS, label)
    category = _nonempty_string(value["category"], f"{label}.category")
    package = _nonempty_string(value["package"], f"{label}.package")
    version = _nonempty_string(value["version"], f"{label}.version")
    advisory_id = value["advisory_id"]
    if advisory_id is not None:
        advisory_id = _nonempty_string(advisory_id, f"{label}.advisory_id")
    return category, advisory_id, package, version


def approved_warnings(
    policy: Any,
    *,
    today: date,
    allow_expired: bool = False,
) -> dict[WarningIdentity, str]:
    if not isinstance(policy, dict):
        raise PolicyError("policy must be an object")
    _exact_keys(policy, POLICY_KEYS, "policy")
    if policy["schema_version"] != 1:
        raise PolicyError("policy.schema_version must equal 1")
    reviewed_on = date.fromisoformat(
        _nonempty_string(policy["reviewed_on"], "policy.reviewed_on")
    )
    if reviewed_on > today:
        raise PolicyError("policy.reviewed_on must not be in the future")

    groups = policy["exception_groups"]
    if not isinstance(groups, list):
        raise PolicyError("policy.exception_groups must be an array")

    approved: dict[WarningIdentity, str] = {}
    group_ids: set[str] = set()
    for group_index, group in enumerate(groups):
        label = f"policy.exception_groups[{group_index}]"
        if not isinstance(group, dict):
            raise PolicyError(f"{label} must be an object")
        _exact_keys(group, GROUP_KEYS, label)
        group_id = _nonempty_string(group["id"], f"{label}.id")
        if group_id in group_ids:
            raise PolicyError(f"duplicate exception group id: {group_id}")
        group_ids.add(group_id)
        _nonempty_string(group["owner"], f"{label}.owner")
        _nonempty_string(group["reason"], f"{label}.reason")
        _nonempty_string(group["exit_condition"], f"{label}.exit_condition")
        expires_on = date.fromisoformat(
            _nonempty_string(group["expires_on"], f"{label}.expires_on")
        )
        if expires_on < today and not allow_expired:
            raise PolicyError(
                f"exception group {group_id} expired on {expires_on.isoformat()}"
            )
        warnings = group["warnings"]
        if not isinstance(warnings, list) or not warnings:
            raise PolicyError(f"{label}.warnings must be a non-empty array")
        for warning_index, warning in enumerate(warnings):
            identity = _policy_identity(
                warning,
                f"{label}.warnings[{warning_index}]",
            )
            if identity in approved:
                raise PolicyError(
                    f"duplicate warning exception: {format_identity(identity)}"
                )
            approved[identity] = group_id
    return approved


def validate_publication_policy(
    source_policy: Any,
    authorization_policy: Any,
    *,
    today: date,
    source_packages: set[tuple[str, str]],
) -> None:
    authorized = set(approved_warnings(authorization_policy, today=today))
    required = {
        identity
        for identity in approved_warnings(source_policy, today=today, allow_expired=True)
        if (identity[2], identity[3]) in source_packages
    }
    if required - authorized:
        raise PolicyError(
            "Current policy does not authorize all release-source warnings: "
            + ", ".join(sorted(map(format_identity, required - authorized)))
        )


def lockfile_packages(path: Path) -> set[tuple[str, str]]:
    packages = tomllib.loads(path.read_text(encoding="utf-8")).get("package")
    if not isinstance(packages, list) or not packages:
        raise PolicyError("Release lockfile must contain packages")
    result: set[tuple[str, str]] = set()
    for package in packages:
        if not isinstance(package, dict):
            raise PolicyError("Release lockfile package must be an object")
        result.add(
            (
                _nonempty_string(package.get("name"), "lockfile package name"),
                _nonempty_string(package.get("version"), "lockfile package version"),
            )
        )
    return result


def report_warnings(report: Any) -> set[WarningIdentity]:
    if not isinstance(report, dict):
        raise PolicyError("cargo-audit report must be an object")
    warnings = report.get("warnings")
    if not isinstance(warnings, dict):
        raise PolicyError("cargo-audit report warnings must be an object")

    identities: set[WarningIdentity] = set()
    for category, entries in warnings.items():
        if not isinstance(category, str) or not isinstance(entries, list):
            raise PolicyError("cargo-audit warning categories are malformed")
        for entry in entries:
            if not isinstance(entry, dict):
                raise PolicyError("cargo-audit warning entry must be an object")
            package = entry.get("package")
            advisory = entry.get("advisory")
            if not isinstance(package, dict):
                raise PolicyError("cargo-audit warning package is malformed")
            advisory_id = (
                advisory.get("id") if isinstance(advisory, dict) else None
            )
            identity = (
                category,
                advisory_id,
                str(package.get("name", "")),
                str(package.get("version", "")),
            )
            if not identity[2] or not identity[3]:
                raise PolicyError("cargo-audit warning identity is incomplete")
            identities.add(identity)
    return identities


def format_identity(identity: WarningIdentity) -> str:
    category, advisory_id, package, version = identity
    return f"{category}:{advisory_id or 'none'}:{package}@{version}"


def evaluate_report(
    report: Any,
    policy: Any,
    *,
    today: date,
) -> tuple[list[str], set[WarningIdentity], set[WarningIdentity]]:
    approved = set(approved_warnings(policy, today=today))
    actual = report_warnings(report)
    errors: list[str] = []

    vulnerabilities = (
        report.get("vulnerabilities", {}).get("list", [])
        if isinstance(report, dict)
        else []
    )
    if not isinstance(vulnerabilities, list):
        raise PolicyError("cargo-audit vulnerabilities list is malformed")
    for vulnerability in vulnerabilities:
        advisory = vulnerability.get("advisory", {})
        package = vulnerability.get("package", {})
        errors.append(
            "Rust vulnerability: "
            f"{advisory.get('id', 'unknown')} "
            f"{package.get('name', 'unknown')}@{package.get('version', 'unknown')}"
        )

    for identity in sorted(actual - approved, key=format_identity):
        errors.append(f"Unapproved cargo-audit warning: {format_identity(identity)}")
    return errors, actual & approved, approved - actual


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--policy",
        type=Path,
        default=Path(".github/config/cargo-audit-policy.json"),
    )
    parser.add_argument(
        "--policy-only",
        action="store_true",
        help="Validate policy structure and deadlines without running Cargo.",
    )
    parser.add_argument(
        "--authorization-policy",
        type=Path,
        help="Current trusted policy authorizing publication of the source graph.",
    )
    parser.add_argument(
        "--lockfile",
        type=Path,
        default=Path("Cargo.lock"),
        help="Frozen source lockfile used for publication policy validation.",
    )
    args = parser.parse_args()
    if args.authorization_policy and not args.policy_only:
        parser.error("--authorization-policy requires --policy-only")

    try:
        policy = json.loads(args.policy.read_text(encoding="utf-8"))
        if args.policy_only:
            if args.authorization_policy:
                authorization = json.loads(
                    args.authorization_policy.read_text(encoding="utf-8")
                )
                validate_publication_policy(
                    policy,
                    authorization,
                    today=date.today(),
                    source_packages=lockfile_packages(args.lockfile),
                )
            else:
                approved_warnings(policy, today=date.today())
            print("Dependency policy structure and deadlines are valid.")
            return 0
        process = subprocess.run(
            ["cargo", "audit", "--json"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        report = json.loads(process.stdout)
        errors, active, inactive = evaluate_report(
            report,
            policy,
            today=date.today(),
        )
        if process.returncode != 0 and not errors:
            detail = process.stderr.strip().splitlines()
            errors.append(
                "cargo audit failed without a parseable vulnerability: "
                + (detail[-1] if detail else f"exit {process.returncode}")
            )
    except (OSError, json.JSONDecodeError, PolicyError, ValueError) as error:
        print(f"Cargo dependency audit configuration error: {error}", file=sys.stderr)
        return 2

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(
        "Cargo dependency audit passed: 0 vulnerabilities, "
        f"{len(active)} approved warnings, 0 unexpected warnings"
        + (f", {len(inactive)} inactive exceptions" if inactive else "")
        + "."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

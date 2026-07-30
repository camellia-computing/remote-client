from __future__ import annotations

from datetime import date
import importlib.util
from pathlib import Path
import unittest


SCRIPT_PATH = Path(__file__).parents[1] / "audit_cargo_dependencies.py"
SPEC = importlib.util.spec_from_file_location("audit_cargo_dependencies", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
AUDITOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDITOR)


def warning(
    *,
    category: str = "unsound",
    advisory_id: str | None = "RUSTSEC-2099-0001",
    package: str = "example",
    version: str = "1.0.0",
) -> dict[str, object]:
    return {
        "kind": category,
        "package": {"name": package, "version": version},
        "advisory": None if advisory_id is None else {"id": advisory_id},
    }


def policy_warning() -> dict[str, object]:
    return {
        "category": "unsound",
        "advisory_id": "RUSTSEC-2099-0001",
        "package": "example",
        "version": "1.0.0",
    }


def policy(*, expires_on: str = "2099-12-31") -> dict[str, object]:
    return {
        "schema_version": 1,
        "reviewed_on": "2026-07-29",
        "exception_groups": [
            {
                "id": "reviewed-example",
                "owner": "remote-security-maintainers",
                "expires_on": expires_on,
                "reason": "Test-only reviewed warning.",
                "exit_condition": "Remove the dependency.",
                "warnings": [policy_warning()],
            }
        ],
    }


def report(
    *,
    warnings: list[dict[str, object]] | None = None,
    vulnerabilities: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "warnings": {"unsound": warnings or []},
        "vulnerabilities": {"list": vulnerabilities or []},
    }


class CargoAuditPolicyTests(unittest.TestCase):
    def test_reviewed_warning_passes(self) -> None:
        errors, active, inactive = AUDITOR.evaluate_report(
            report(warnings=[warning()]),
            policy(),
            today=date(2026, 7, 29),
        )
        self.assertEqual(errors, [])
        self.assertEqual(len(active), 1)
        self.assertEqual(inactive, set())

    def test_unapproved_warning_fails(self) -> None:
        errors, _, _ = AUDITOR.evaluate_report(
            report(
                warnings=[
                    warning(
                        advisory_id="RUSTSEC-2099-0002",
                        package="new-warning",
                    )
                ]
            ),
            policy(),
            today=date(2026, 7, 29),
        )
        self.assertRegex(errors[0], "Unapproved cargo-audit warning")

    def test_vulnerability_always_fails(self) -> None:
        errors, _, _ = AUDITOR.evaluate_report(
            report(
                vulnerabilities=[
                    {
                        "advisory": {"id": "RUSTSEC-2099-9999"},
                        "package": {"name": "vulnerable", "version": "1.0.0"},
                    }
                ]
            ),
            policy(),
            today=date(2026, 7, 29),
        )
        self.assertRegex(errors[0], "Rust vulnerability")

    def test_expired_exception_fails_policy_validation(self) -> None:
        with self.assertRaisesRegex(AUDITOR.PolicyError, "expired"):
            AUDITOR.evaluate_report(
                report(warnings=[warning()]),
                policy(expires_on="2026-07-27"),
                today=date(2026, 7, 29),
            )

    def test_duplicate_warning_exception_is_rejected(self) -> None:
        duplicate_policy = policy()
        duplicate_policy["exception_groups"][0]["warnings"].append(policy_warning())
        with self.assertRaisesRegex(AUDITOR.PolicyError, "duplicate warning"):
            AUDITOR.evaluate_report(
                report(warnings=[warning()]),
                duplicate_policy,
                today=date(2026, 7, 29),
            )


if __name__ == "__main__":
    unittest.main()

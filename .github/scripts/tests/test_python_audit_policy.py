from pathlib import Path
import unittest


ROOT = Path(__file__).parents[3]


class PythonAuditPolicyTests(unittest.TestCase):
    def test_auditor_is_isolated_and_has_one_pinned_source(self) -> None:
        pin = (ROOT / "libs/portable/requirements-audit.txt").read_text().strip()
        self.assertRegex(pin, r"^pip-audit==\d+\.\d+\.\d+$")
        helper = (ROOT / ".github/scripts/audit_python_dependencies.sh").read_text()
        self.assertIn('-m venv "$audit_environment"', helper)
        self.assertIn("libs/portable/requirements-audit.txt", helper)
        self.assertIn("--no-deps --disable-pip", helper)
        self.assertNotIn("--ignore-vuln", helper)

    def test_current_and_scheduled_checks_cover_portable_requirements(self) -> None:
        for name in ["ci.yml", "security-audit.yml"]:
            workflow = (ROOT / ".github/workflows" / name).read_text()
            self.assertIn("run: bash .github/scripts/audit_python_dependencies.sh", workflow)
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("*/requirements*.txt", workflow)
        dependabot = (ROOT / ".github/dependabot.yml").read_text()
        self.assertRegex(dependabot, r"package-ecosystem: pip\s+directory: /libs/portable")


if __name__ == "__main__":
    unittest.main()

import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "verify_apple_deployment.py"
SPEC = importlib.util.spec_from_file_location("verify_apple_deployment", MODULE_PATH)
apple_policy = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(apple_policy)


class AppleDeploymentPolicyTests(unittest.TestCase):
    def test_repository_policy_is_consistent(self) -> None:
        apple_policy.verify()

    def test_version_parser_rejects_ambiguous_values(self) -> None:
        self.assertEqual(apple_policy.version_tuple("13.0", "test"), (13, 0))
        for value in ("13", "13.0.1", "latest"):
            with self.subTest(value=value), self.assertRaises(
                apple_policy.PolicyError
            ):
                apple_policy.version_tuple(value, "test")

    def test_job_environment_requires_one_exact_value(self) -> None:
        job = '    env:\n      IPHONEOS_DEPLOYMENT_TARGET: "13.0"\n    steps:\n'
        apple_policy.require_job_environment(
            job,
            "IPHONEOS_DEPLOYMENT_TARGET",
            "13.0",
            "test job",
        )
        with self.assertRaises(apple_policy.PolicyError):
            apple_policy.require_job_environment(
                job,
                "IPHONEOS_DEPLOYMENT_TARGET",
                "14.0",
                "test job",
            )

    def test_job_runner_requires_one_exact_label(self) -> None:
        job = "    runs-on: macos-26\n    steps:\n"
        apple_policy.require_job_runner(job, "macos-26", "test job")
        with self.assertRaises(apple_policy.PolicyError):
            apple_policy.require_job_runner(job, "macos-15", "test job")

    def test_job_command_requires_one_exact_occurrence(self) -> None:
        job = "    steps:\n      - run: git diff --exit-code\n"
        apple_policy.require_job_command(
            job, "git diff --exit-code", "test command"
        )
        for invalid in ("", job + "      - run: git diff --exit-code\n"):
            with self.subTest(invalid=invalid), self.assertRaises(
                apple_policy.PolicyError
            ):
                apple_policy.require_job_command(
                    invalid, "git diff --exit-code", "test command"
                )

    def test_missing_workflow_job_is_rejected(self) -> None:
        with self.assertRaises(apple_policy.PolicyError):
            apple_policy.workflow_job("jobs:\n", "apple_native", "test workflow")

    def test_runtime_dependencies_must_target_the_product(self) -> None:
        apple_policy.verify_target_only_vcpkg_dependencies(
            {"dependencies": ["aom", {"name": "libvpx", "host": False}]}
        )
        with self.assertRaises(apple_policy.PolicyError):
            apple_policy.verify_target_only_vcpkg_dependencies(
                {"dependencies": [{"name": "libvpx", "host": True}]}
            )


if __name__ == "__main__":
    unittest.main()

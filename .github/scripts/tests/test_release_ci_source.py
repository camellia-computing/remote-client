from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT_PATH = Path(__file__).parents[1] / "select_release_ci_run.py"
CI_WORKFLOW_PATH = Path(__file__).parents[2] / "workflows" / "ci.yml"
SPEC = importlib.util.spec_from_file_location("select_release_ci_run", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
SELECTOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SELECTOR
SPEC.loader.exec_module(SELECTOR)


COMMIT = "a" * 40


def run(
    identifier: int,
    *,
    event: str = "push",
    branch: str = "main",
    sha: str = COMMIT,
    conclusion: str = "success",
    run_number: int | None = None,
) -> dict[str, object]:
    return {
        "id": identifier,
        "event": event,
        "head_branch": branch,
        "head_sha": sha,
        "conclusion": conclusion,
        "run_number": run_number if run_number is not None else identifier,
    }


class ReleaseCiSourceTests(unittest.TestCase):
    def test_selects_latest_exact_default_branch_push_or_manual_full_ci(self) -> None:
        selected = SELECTOR.select_release_ci_run(
            [
                run(10, event="push"),
                run(20, event="workflow_dispatch"),
                run(30, event="pull_request", run_number=99),
            ],
            commit=COMMIT,
            default_branch="main",
        )

        self.assertEqual(selected, 20)

    def test_rejects_non_default_branch_or_untrusted_event_or_mismatched_source(self) -> None:
        candidates = [
            run(1, branch="feature/release"),
            run(2, event="schedule"),
            run(3, event="pull_request"),
            run(4, sha="b" * 40),
            run(5, conclusion="failure"),
            {"id": "not-an-integer", "event": "push"},
        ]

        with self.assertRaises(SELECTOR.ReleaseCiRunError):
            SELECTOR.select_release_ci_run(
                candidates,
                commit=COMMIT,
                default_branch="main",
            )

    def test_rejects_a_malformed_run_list(self) -> None:
        with self.assertRaises(SELECTOR.ReleaseCiRunError):
            SELECTOR.select_release_ci_run(
                {"not": "a list"},
                commit=COMMIT,
                default_branch="main",
            )

    def test_manual_ci_dispatch_enables_every_release_relevant_gate(self) -> None:
        workflow = CI_WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertIn(
            'if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then\n'
            '            runtime=true\n'
            '            automation=true\n'
            '            dependencies=true',
            workflow,
        )

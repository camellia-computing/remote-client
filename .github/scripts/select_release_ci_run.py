#!/usr/bin/env python3
"""Select the exact full default-branch CI run eligible for a release source."""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any


ALLOWED_EVENTS = {"push", "workflow_dispatch"}


class ReleaseCiRunError(ValueError):
    """Raised when a source commit has no eligible CI evidence."""


def _run_number(run: dict[str, Any]) -> int:
    value = run.get("run_number")
    return value if isinstance(value, int) and not isinstance(value, bool) else -1


def select_release_ci_run(
    workflow_runs: Any,
    *,
    commit: str,
    default_branch: str,
) -> int:
    if not isinstance(workflow_runs, list):
        raise ReleaseCiRunError("workflow run response must contain a run list")

    eligible: list[dict[str, Any]] = []
    for run in workflow_runs:
        if not isinstance(run, dict):
            continue
        if run.get("event") not in ALLOWED_EVENTS:
            continue
        if run.get("head_sha") != commit or run.get("head_branch") != default_branch:
            continue
        if run.get("conclusion") != "success":
            continue
        if _run_number(run) < 1:
            continue
        run_id = run.get("id")
        if (
            not isinstance(run_id, int)
            or isinstance(run_id, bool)
            or run_id < 1
        ):
            continue
        eligible.append(run)

    if not eligible:
        raise ReleaseCiRunError(
            "no successful full default-branch push or workflow_dispatch CI run "
            f"exists for {commit}"
        )
    return max(eligible, key=_run_number)["id"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--default-branch", required=True)
    args = parser.parse_args(argv)

    try:
        payload = json.load(sys.stdin)
        runs = payload.get("workflow_runs") if isinstance(payload, dict) else None
        print(select_release_ci_run(runs, commit=args.commit, default_branch=args.default_branch))
    except (json.JSONDecodeError, ReleaseCiRunError) as error:
        print(f"release CI source error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

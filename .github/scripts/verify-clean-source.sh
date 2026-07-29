#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

status="$(git status --porcelain=v1 --untracked-files=all)"
if [[ -n "$status" ]]; then
  echo "Build changed the checked-out source tree:" >&2
  printf '%s\n' "$status" >&2
  exit 1
fi

echo "Checked-out source tree remains clean"

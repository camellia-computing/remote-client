#!/usr/bin/env bash
set -euo pipefail

nested_cargo_locks="$(
	while IFS= read -r lock_path; do
		if [[ -f "$lock_path" ]]; then
			printf '%s\n' "$lock_path"
		fi
	done < <(git ls-files '*/Cargo.lock')
)"
if [[ -n "$nested_cargo_locks" ]]; then
	echo "Workspace members must use the reviewed root Cargo.lock:" >&2
	printf '%s\n' "$nested_cargo_locks" >&2
	exit 1
fi

echo "Cargo dependency lock scope tests passed"

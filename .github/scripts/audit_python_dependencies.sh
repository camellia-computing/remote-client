#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
audit_environment="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/camellia-python-audit.XXXXXX")"
trap 'rm -rf "$audit_environment"' EXIT

python3 -m venv "$audit_environment"
"$audit_environment/bin/python" -m pip install --quiet --disable-pip-version-check \
  -r "$repository_root/libs/portable/requirements-audit.txt"
"$audit_environment/bin/python" -m pip_audit --no-deps --disable-pip \
  -r "$repository_root/libs/portable/requirements.txt"

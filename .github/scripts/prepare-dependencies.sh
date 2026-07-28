#!/usr/bin/env bash
set -euo pipefail

mode="${1:-locked}"

if [[ "${mode}" != "locked" ]]; then
  echo "Release dependencies must use committed lock files" >&2
  exit 2
fi

cargo fetch --locked
(cd flutter && flutter pub get --enforce-lockfile)
if [[ -f flutter/web/js/package.json ]]; then
  if [[ ! -f flutter/web/js/package-lock.json ]]; then
    echo "Missing flutter/web/js/package-lock.json" >&2
    exit 3
  fi
  (cd flutter/web/js && npm ci)
fi

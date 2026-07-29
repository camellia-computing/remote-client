#!/usr/bin/env bash
set -euo pipefail

repository="$(cd "$(dirname "$0")/../../.." && pwd)"
test_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/camellia-clean-source-tests.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

git -C "$test_root" init -q
git -C "$test_root" config user.email test@example.invalid
git -C "$test_root" config user.name "Camellia Test"
printf 'tracked\n' > "$test_root/tracked.txt"
printf 'ignored.txt\n' > "$test_root/.gitignore"
git -C "$test_root" add .gitignore tracked.txt
git -C "$test_root" commit -q -m fixture

(
  cd "$test_root"
  bash "$repository/.github/scripts/verify-clean-source.sh" >/dev/null
)

printf 'changed\n' > "$test_root/tracked.txt"
if (
  cd "$test_root"
  bash "$repository/.github/scripts/verify-clean-source.sh" >/dev/null 2>&1
); then
  echo "tracked source mutation unexpectedly passed" >&2
  exit 1
fi
git -C "$test_root" restore tracked.txt

printf 'untracked\n' > "$test_root/untracked.txt"
if (
  cd "$test_root"
  bash "$repository/.github/scripts/verify-clean-source.sh" >/dev/null 2>&1
); then
  echo "untracked source mutation unexpectedly passed" >&2
  exit 1
fi
rm -f -- "$test_root/untracked.txt"

printf 'ignored\n' > "$test_root/ignored.txt"
(
  cd "$test_root"
  bash "$repository/.github/scripts/verify-clean-source.sh" >/dev/null
)

echo "Clean source verification tests passed"

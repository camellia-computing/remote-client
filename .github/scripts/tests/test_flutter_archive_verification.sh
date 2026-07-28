#!/usr/bin/env bash
set -euo pipefail

repository="$(cd "$(dirname "$0")/../../.." && pwd)"
verifier="$repository/.github/actions/setup-flutter/verify-sha256.sh"
test_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/camellia-flutter-sha256-tests.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

archive="$test_root/flutter-sdk.tar.xz"
printf 'verified Flutter archive\n' > "$archive"
expected="$(
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$archive" | awk 'NR == 1 { print $1 }'
	else
		sha256sum "$archive" | awk 'NR == 1 { print $1 }'
	fi
)"

bash "$verifier" "$expected" "$archive"
bash "$verifier" "$(printf '%s' "$expected" | tr '[:lower:]' '[:upper:]')" "$archive"

printf 'tampered\n' >> "$archive"
if bash "$verifier" "$expected" "$archive" >/dev/null 2>&1; then
	echo "Tampered Flutter archive unexpectedly passed SHA-256 verification" >&2
	exit 1
fi
if bash "$verifier" invalid "$archive" >/dev/null 2>&1; then
	echo "Malformed expected Flutter digest unexpectedly passed validation" >&2
	exit 1
fi
if bash "$verifier" "$expected" "$test_root/missing.tar.xz" >/dev/null 2>&1; then
	echo "Missing Flutter archive unexpectedly passed SHA-256 verification" >&2
	exit 1
fi

echo "Portable Flutter archive verification tests passed"

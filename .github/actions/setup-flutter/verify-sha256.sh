#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
	echo "Usage: verify-sha256.sh <expected-sha256> <file>" >&2
	exit 2
fi

expected_sha256="$1"
file_path="$2"

if [[ ! "$expected_sha256" =~ ^[0-9a-fA-F]{64}$ ]]; then
	echo "Expected SHA-256 digest is not 64 hexadecimal characters" >&2
	exit 1
fi
if [[ ! -f "$file_path" ]]; then
	echo "SHA-256 input is not a regular file: $file_path" >&2
	exit 1
fi

# macOS shasum and GNU sha256sum expose different verification flags. Compute
# the digest directly so the same path works on hosted macOS, Linux, and Git
# for Windows runners without assuming either command's check-mode dialect.
if command -v shasum >/dev/null 2>&1; then
	actual_sha256="$(shasum -a 256 "$file_path" | awk 'NR == 1 { print $1 }')"
elif command -v sha256sum >/dev/null 2>&1; then
	actual_sha256="$(sha256sum "$file_path" | awk 'NR == 1 { print $1 }')"
else
	echo "No SHA-256 verification utility is available" >&2
	exit 1
fi

expected_sha256="$(printf '%s' "$expected_sha256" | tr '[:upper:]' '[:lower:]')"
actual_sha256="$(printf '%s' "$actual_sha256" | tr '[:upper:]' '[:lower:]')"
# Both GNU sha256sum and Perl shasum prefix the digest with a backslash when
# their displayed filename contains a backslash. Git for Windows passes native
# paths in that form, so remove only that output-format marker before applying
# the strict digest validation below.
actual_sha256="${actual_sha256#\\}"
if [[ ! "$actual_sha256" =~ ^[0-9a-f]{64}$ ]]; then
	echo "SHA-256 utility returned an invalid digest" >&2
	exit 1
fi
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
	echo "SHA-256 mismatch for $file_path" >&2
	echo "Expected: $expected_sha256" >&2
	echo "Actual:   $actual_sha256" >&2
	exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

repository="$(cd "$(dirname "$0")/../../.." && pwd)"
verifier="$repository/.github/actions/setup-flutter/verify-sha256.sh"
test_parent="${RUNNER_TEMP:-/tmp}"
if [[ "${RUNNER_OS:-}" == "Windows" ]]; then
	test_parent="$(cygpath -u "$test_parent")"
fi
test_root="$(mktemp -d "$test_parent/camellia-flutter-sha256-tests.XXXXXX")"
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

# Checksum utilities escape filenames containing backslashes by prefixing the
# printed digest with a backslash. Exercise a native Windows path on Git for
# Windows and reproduce the same output format with a literal filename on Unix.
if [[ "${RUNNER_OS:-}" == "Windows" ]]; then
	windows_archive="$(cygpath -w "$archive")"
	bash "$verifier" "$expected" "$windows_archive"
else
	escaped_archive="$test_root/flutter\\windows.zip"
	cp "$archive" "$escaped_archive"
	bash "$verifier" "$expected" "$escaped_archive"
fi

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

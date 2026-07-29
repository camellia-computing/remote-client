#!/usr/bin/env bash
set -euo pipefail

expected_version="${1:?exact Xcode version is required}"
if [[ ! "$expected_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Xcode version must use major.minor or major.minor.patch form" >&2
  exit 2
fi

: "${DEVELOPER_DIR:?DEVELOPER_DIR is required}"
expected_developer_dir="/Applications/Xcode_${expected_version}.app/Contents/Developer"
if [[ "$DEVELOPER_DIR" != "$expected_developer_dir" ]]; then
  echo "DEVELOPER_DIR must be $expected_developer_dir" >&2
  exit 1
fi
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Pinned Xcode developer directory does not exist: $DEVELOPER_DIR" >&2
  exit 1
fi

actual_version="$(
  xcodebuild -version |
    awk 'NR == 1 && $1 == "Xcode" { print $2 }'
)"
if [[ "$actual_version" != "$expected_version" ]]; then
  echo "Expected Xcode $expected_version, got ${actual_version:-unknown}" >&2
  exit 1
fi

iphoneos_sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
macos_sdk="$(xcrun --sdk macosx --show-sdk-version)"
printf 'Verified Xcode %s (iPhoneOS SDK %s, macOS SDK %s)\n' \
  "$actual_version" "$iphoneos_sdk" "$macos_sdk"

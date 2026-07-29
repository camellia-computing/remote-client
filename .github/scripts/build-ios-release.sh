#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${IOS_NATIVE_SIGNING:?IOS_NATIVE_SIGNING is required}"

cd "$GITHUB_WORKSPACE/flutter"
case "$IOS_NATIVE_SIGNING" in
  signed)
    : "${IOS_EXPORT_OPTIONS_PLIST:?IOS_EXPORT_OPTIONS_PLIST is required}"
    flutter build ipa \
      --release \
      --export-options-plist="$IOS_EXPORT_OPTIONS_PLIST"
    ;;
  unsigned)
    flutter build ipa --release --no-codesign
    ;;
  *)
    echo "Unsupported IOS_NATIVE_SIGNING mode: $IOS_NATIVE_SIGNING" >&2
    exit 2
    ;;
esac

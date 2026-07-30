#!/usr/bin/env bash
set -euo pipefail

: "${COCOAPODS_VERSION:?COCOAPODS_VERSION is required}"

case "$*" in
  ios | macos | "ios macos") ;;
  *)
    echo "Usage: $0 ios [macos] | macos" >&2
    exit 2
    ;;
esac

actual_version="$(pod --version)"
[[ "$actual_version" == "$COCOAPODS_VERSION" ]] || {
  echo "Expected CocoaPods $COCOAPODS_VERSION, found $actual_version" >&2
  exit 1
}

lockfiles=()
for platform in "$@"; do
  lockfile="flutter/$platform/Podfile.lock"
  [[ -f "$lockfile" ]] || {
    echo "Missing committed $lockfile" >&2
    exit 1
  }
  lockfiles+=("$lockfile")
  (
    cd "flutter/$platform"
    pod install --no-repo-update
  )
done

if ! git diff --exit-code -- "${lockfiles[@]}"; then
  echo "Apple Pod locks are stale; regenerate them with CocoaPods $COCOAPODS_VERSION" >&2
  exit 1
fi

echo "Apple Pod locks match CocoaPods $COCOAPODS_VERSION resolution: ${lockfiles[*]}"

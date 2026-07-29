#!/usr/bin/env bash
set -euo pipefail

: "${COCOAPODS_VERSION:?COCOAPODS_VERSION is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

[[ "$COCOAPODS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "COCOAPODS_VERSION must be an exact semantic version" >&2
  exit 2
}

brew install nasm
gem install \
  --user-install \
  cocoapods \
  --version "$COCOAPODS_VERSION" \
  --no-document

gem_bin="$(ruby -e 'print Gem.user_dir')/bin"
pod_version="$("$gem_bin/pod" --version)"
[[ "$pod_version" == "$COCOAPODS_VERSION" ]] || {
  echo "Expected CocoaPods $COCOAPODS_VERSION, found $pod_version" >&2
  exit 1
}

printf '%s\n' "$gem_bin" >> "$GITHUB_PATH"
echo "CocoaPods $pod_version and NASM are ready"

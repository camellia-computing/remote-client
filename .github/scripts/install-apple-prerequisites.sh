#!/usr/bin/env bash
set -euo pipefail

: "${COCOAPODS_VERSION:?COCOAPODS_VERSION is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
json_version="$(tr -d '\r\n' < "$repository_root/.github/config/cocoapods-json-version")"

[[ "$COCOAPODS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "COCOAPODS_VERSION must be an exact semantic version" >&2
  exit 2
}
[[ "$json_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'CocoaPods JSON must be an exact semantic version' >&2
  exit 2
}

brew install nasm
gem install \
  --user-install \
  cocoapods \
  --version "$COCOAPODS_VERSION" \
  --no-document
gem install --user-install json --version "$json_version" --no-document

gem_bin="$(mktemp -d "$RUNNER_TEMP/camellia-apple-tools.XXXXXX")"
ln -s "$repository_root/.github/scripts/pod.rb" "$gem_bin/pod"
pod_version="$("$gem_bin/pod" --version)"
[[ "$pod_version" == "$COCOAPODS_VERSION" ]] || {
  echo "Expected CocoaPods $COCOAPODS_VERSION, found $pod_version" >&2
  exit 1
}

printf '%s\n' "$gem_bin" >> "$GITHUB_PATH"
echo "CocoaPods $pod_version, JSON $json_version and NASM are ready"

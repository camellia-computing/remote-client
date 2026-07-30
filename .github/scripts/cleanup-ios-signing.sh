#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${IOS_ORIGINAL_KEYCHAINS_FILE:-}" &&
      -f "$IOS_ORIGINAL_KEYCHAINS_FILE" &&
      ! -L "$IOS_ORIGINAL_KEYCHAINS_FILE" ]]; then
  original_keychains=()
  while IFS= read -r keychain; do
    keychain="$(
      sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' <<< "$keychain"
    )"
    [[ -z "$keychain" ]] || original_keychains+=("$keychain")
  done < "$IOS_ORIGINAL_KEYCHAINS_FILE"
  if ((${#original_keychains[@]} > 0)); then
    security list-keychains -d user -s "${original_keychains[@]}"
  fi
fi
if [[ -n "${IOS_KEYCHAIN_PATH:-}" ]]; then
  security delete-keychain "$IOS_KEYCHAIN_PATH" >/dev/null 2>&1 || true
fi

cleanup_paths=()
for path in \
  "${IOS_CERTIFICATE_PATH:-}" \
  "${IOS_PROVISIONING_PROFILE_PATH:-}" \
  "${IOS_INSTALLED_PROFILE_PATH:-}" \
  "${IOS_SIGNING_XCCONFIG_PATH:-}" \
  "${IOS_PROFILE_PLIST_PATH:-}" \
  "${IOS_PROFILE_ENVIRONMENT_PATH:-}" \
  "${IOS_CERTIFICATE_PEM_PATH:-}" \
  "${IOS_EXPORT_OPTIONS_PLIST:-}" \
  "${IOS_ORIGINAL_KEYCHAINS_FILE:-}"; do
  [[ -z "$path" ]] || cleanup_paths+=("$path")
done
if ((${#cleanup_paths[@]} > 0)); then
  rm -f -- "${cleanup_paths[@]}"
fi

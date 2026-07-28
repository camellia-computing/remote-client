#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${MACOS_ORIGINAL_KEYCHAINS_FILE:-}" && \
      -f "$MACOS_ORIGINAL_KEYCHAINS_FILE" && \
      ! -L "$MACOS_ORIGINAL_KEYCHAINS_FILE" ]]; then
  original_keychains=()
  while IFS= read -r keychain; do
    keychain="$(
      sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' <<< "$keychain"
    )"
    [[ -z "$keychain" ]] || original_keychains+=("$keychain")
  done < "$MACOS_ORIGINAL_KEYCHAINS_FILE"
  if ((${#original_keychains[@]} > 0)); then
    security list-keychains -d user -s "${original_keychains[@]}"
  fi
fi
if [[ -n "${MACOS_KEYCHAIN_PATH:-}" ]]; then
  security delete-keychain "$MACOS_KEYCHAIN_PATH" >/dev/null 2>&1 || true
fi
cleanup_paths=()
for path in \
  "${MACOS_CERTIFICATE_PATH:-}" \
  "${APPLE_API_KEY_PATH:-}" \
  "${MACOS_ORIGINAL_KEYCHAINS_FILE:-}"; do
  [[ -z "$path" ]] || cleanup_paths+=("$path")
done
if ((${#cleanup_paths[@]} > 0)); then
  rm -f -- "${cleanup_paths[@]}"
fi

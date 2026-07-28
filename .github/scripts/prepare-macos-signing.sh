#!/usr/bin/env bash
set -euo pipefail

: "${APPLE_CERTIFICATE_PASSWORD:?APPLE_CERTIFICATE_PASSWORD is required}"
: "${MACOS_CERTIFICATE_PATH:?MACOS_CERTIFICATE_PATH is required}"
: "${MACOS_SIGNING_IDENTITY:?MACOS_SIGNING_IDENTITY is required}"
: "${SIGNING_ENV_FILE:?SIGNING_ENV_FILE is required}"
: "${SIGNING_TEMP_DIRECTORY:?SIGNING_TEMP_DIRECTORY is required}"

[[ -f "$MACOS_CERTIFICATE_PATH" && ! -L "$MACOS_CERTIFICATE_PATH" ]] || {
  echo 'The resolved macOS P12 is unavailable or is a symbolic link' >&2
  exit 2
}

keychain_path="$SIGNING_TEMP_DIRECTORY/camellia-remote-signing.keychain-db"
original_keychains="$SIGNING_TEMP_DIRECTORY/camellia-remote-original-keychains.txt"
keychain_password="$(openssl rand -base64 48 | tr -d '\r\n')"
security list-keychains -d user > "$original_keychains"
{
  echo "MACOS_KEYCHAIN_PATH=$keychain_path"
  echo "MACOS_ORIGINAL_KEYCHAINS_FILE=$original_keychains"
} >> "$SIGNING_ENV_FILE"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$MACOS_CERTIFICATE_PATH" \
  -k "$keychain_path" \
  -P "$APPLE_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$keychain_password" \
  "$keychain_path" >/dev/null

existing_keychains=()
while IFS= read -r keychain; do
  keychain="$(
    sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' <<< "$keychain"
  )"
  [[ -z "$keychain" ]] || existing_keychains+=("$keychain")
done < "$original_keychains"
security list-keychains -d user -s "$keychain_path" "${existing_keychains[@]}"
if ! security find-identity -v -p codesigning "$keychain_path" |
  grep -F "\"$MACOS_SIGNING_IDENTITY\"" >/dev/null; then
  echo "Imported P12 does not contain the configured identity: $MACOS_SIGNING_IDENTITY" >&2
  exit 1
fi

rm -f -- "$MACOS_CERTIFICATE_PATH"
unset keychain_password
echo "Imported macOS identity into an ephemeral keychain: $MACOS_SIGNING_IDENTITY"

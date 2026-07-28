#!/usr/bin/env bash
set -euo pipefail

: "${IOS_CERTIFICATE_PASSWORD:?IOS_CERTIFICATE_PASSWORD is required}"
: "${IOS_CERTIFICATE_PATH:?IOS_CERTIFICATE_PATH is required}"
: "${IOS_PROVISIONING_PROFILE_PATH:?IOS_PROVISIONING_PROFILE_PATH is required}"
: "${IOS_SIGNING_IDENTITY:?IOS_SIGNING_IDENTITY is required}"
: "${IOS_TEAM_ID:?IOS_TEAM_ID is required}"
: "${IOS_EXPORT_METHOD:?IOS_EXPORT_METHOD is required}"
: "${IOS_BUNDLE_ID:?IOS_BUNDLE_ID is required}"
: "${IOS_SIGNING_XCCONFIG_PATH:?IOS_SIGNING_XCCONFIG_PATH is required}"
: "${SIGNING_ENV_FILE:?SIGNING_ENV_FILE is required}"
: "${SIGNING_TEMP_DIRECTORY:?SIGNING_TEMP_DIRECTORY is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

for path in "$IOS_CERTIFICATE_PATH" "$IOS_PROVISIONING_PROFILE_PATH"; do
  [[ -f "$path" && ! -L "$path" ]] || {
    echo "Resolved iOS signing input is unavailable or is a symbolic link: $path" >&2
    exit 2
  }
done
[[ ! -e "$IOS_SIGNING_XCCONFIG_PATH" && ! -L "$IOS_SIGNING_XCCONFIG_PATH" ]] || {
  echo 'Refusing to overwrite an existing iOS Signing.xcconfig' >&2
  exit 1
}

keychain_path="$SIGNING_TEMP_DIRECTORY/camellia-remote-ios-signing.keychain-db"
original_keychains="$SIGNING_TEMP_DIRECTORY/camellia-remote-ios-original-keychains.txt"
profile_plist="$SIGNING_TEMP_DIRECTORY/camellia-remote-ios-profile.plist"
profile_environment="$SIGNING_TEMP_DIRECTORY/camellia-remote-ios-profile.env"
export_options="$SIGNING_TEMP_DIRECTORY/camellia-remote-ios-export-options.plist"
certificate_pem="$SIGNING_TEMP_DIRECTORY/camellia-remote-ios-certificate.pem"
keychain_password="$(openssl rand -base64 48 | tr -d '\r\n')"
security list-keychains -d user > "$original_keychains"
{
  echo "IOS_KEYCHAIN_PATH=$keychain_path"
  echo "IOS_ORIGINAL_KEYCHAINS_FILE=$original_keychains"
  echo "IOS_PROFILE_PLIST_PATH=$profile_plist"
  echo "IOS_PROFILE_ENVIRONMENT_PATH=$profile_environment"
  echo "IOS_CERTIFICATE_PEM_PATH=$certificate_pem"
  echo "IOS_SIGNING_XCCONFIG_PATH=$IOS_SIGNING_XCCONFIG_PATH"
} >> "$SIGNING_ENV_FILE"

security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$IOS_CERTIFICATE_PATH" \
  -k "$keychain_path" \
  -P "$IOS_CERTIFICATE_PASSWORD" \
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
identity_count="$(
  security find-identity -v -p codesigning "$keychain_path" |
    grep -Fc "\"$IOS_SIGNING_IDENTITY\"" || true
)"
[[ "$identity_count" == 1 ]] || {
  echo "Imported P12 must contain exactly one configured identity: $IOS_SIGNING_IDENTITY" >&2
  exit 1
}

security find-certificate \
  -c "$IOS_SIGNING_IDENTITY" \
  -p \
  "$keychain_path" > "$certificate_pem"
certificate_sha256="$(
  openssl x509 -in "$certificate_pem" -outform DER |
    shasum -a 256 |
    awk '{ print toupper($1) }'
)"
[[ "$certificate_sha256" =~ ^[0-9A-F]{64}$ ]] || {
  echo 'Unable to calculate the iOS signing certificate SHA-256 digest' >&2
  exit 1
}

security cms -D -i "$IOS_PROVISIONING_PROFILE_PATH" > "$profile_plist"
python3 "$GITHUB_WORKSPACE/.github/scripts/ios_profile.py" validate \
  --profile-plist "$profile_plist" \
  --bundle-id "$IOS_BUNDLE_ID" \
  --team-id "$IOS_TEAM_ID" \
  --export-method "$IOS_EXPORT_METHOD" \
  --certificate-sha256 "$certificate_sha256" \
  --export-options "$export_options" \
  --environment-output "$profile_environment" \
  --signing-identity "$IOS_SIGNING_IDENTITY"
# The generated file contains only a canonical UUID, digest, and runner-temp path.
# shellcheck disable=SC1090
source "$profile_environment"
cat "$profile_environment" >> "$SIGNING_ENV_FILE"

profiles_directory="${HOME:?}/Library/MobileDevice/Provisioning Profiles"
installed_profile="$profiles_directory/$IOS_PROFILE_UUID.mobileprovision"
mkdir -p "$profiles_directory"
[[ ! -e "$installed_profile" && ! -L "$installed_profile" ]] || {
  echo "Refusing to overwrite an installed profile: $IOS_PROFILE_UUID" >&2
  exit 1
}
cp "$IOS_PROVISIONING_PROFILE_PATH" "$installed_profile"
echo "IOS_INSTALLED_PROFILE_PATH=$installed_profile" >> "$SIGNING_ENV_FILE"

umask 077
{
  printf 'CODE_SIGN_IDENTITY = %s\n' "$IOS_SIGNING_IDENTITY"
  printf 'CODE_SIGN_STYLE = Manual\n'
  printf 'DEVELOPMENT_TEAM = %s\n' "$IOS_TEAM_ID"
  printf 'PROVISIONING_PROFILE_SPECIFIER = %s\n' "$IOS_PROFILE_UUID"
} > "$IOS_SIGNING_XCCONFIG_PATH"

rm -f -- "$IOS_CERTIFICATE_PATH" "$IOS_PROVISIONING_PROFILE_PATH"
unset keychain_password
echo "Imported iOS identity and profile into ephemeral stores: $IOS_PROFILE_UUID"

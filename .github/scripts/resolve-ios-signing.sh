#!/usr/bin/env bash
set -euo pipefail

: "${SIGNING_ENV_FILE:?SIGNING_ENV_FILE is required}"
: "${SIGNING_TEMP_DIRECTORY:?SIGNING_TEMP_DIRECTORY is required}"
[[ -d "$SIGNING_TEMP_DIRECTORY" ]] || {
  echo 'SIGNING_TEMP_DIRECTORY is not a directory' >&2
  exit 2
}

signing_values=(
  IOS_CERTIFICATE_BASE64
  IOS_CERTIFICATE_PASSWORD
  IOS_PROVISIONING_PROFILE_BASE64
  IOS_SIGNING_CERTIFICATE_SHA256
  IOS_SIGNING_IDENTITY
  IOS_TEAM_ID
  IOS_EXPORT_METHOD
)
signing_count=0
for name in "${signing_values[@]}"; do
  [[ -z "${!name:-}" ]] || signing_count=$((signing_count + 1))
done
[[ "$signing_count" == 0 || "$signing_count" == 7 ]] || {
  echo 'IOS_CERTIFICATE_BASE64, IOS_CERTIFICATE_PASSWORD, IOS_PROVISIONING_PROFILE_BASE64, IOS_SIGNING_CERTIFICATE_SHA256, IOS_SIGNING_IDENTITY, IOS_TEAM_ID and IOS_EXPORT_METHOD must be configured together' >&2
  exit 1
}

if [[ "$signing_count" == 0 ]]; then
  {
    echo 'IOS_NATIVE_SIGNING=unsigned'
    echo 'IOS_DISTRIBUTION_TRUST=none'
    echo 'IOS_ARTIFACT_SUFFIX=-unsigned'
  } >> "$SIGNING_ENV_FILE"
  echo 'iOS archive/IPA will be explicit unsigned re-signing inputs'
  exit 0
fi

[[ "$IOS_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || {
  echo 'IOS_TEAM_ID must be a 10-character uppercase Apple Developer Team ID' >&2
  exit 1
}
case "$IOS_EXPORT_METHOD" in
  app-store-connect|release-testing|debugging|enterprise) ;;
  *)
    echo 'IOS_EXPORT_METHOD must be app-store-connect, release-testing, debugging, or enterprise' >&2
    exit 1
    ;;
esac
if [[ -z "$IOS_SIGNING_IDENTITY" ||
      ${#IOS_SIGNING_IDENTITY} -gt 256 ||
      "$IOS_SIGNING_IDENTITY" == *$'\n'* ||
      "$IOS_SIGNING_IDENTITY" == *$'\r'* ||
      "$IOS_SIGNING_IDENTITY" == *'$'* ||
      "$IOS_SIGNING_IDENTITY" == *'#'* ||
      "$IOS_SIGNING_IDENTITY" == *'='* ||
      "$IOS_SIGNING_IDENTITY" == *';'* ||
      "$IOS_SIGNING_IDENTITY" == *\\* ||
      "$IOS_SIGNING_IDENTITY" == *'//'* ]]; then
  echo 'IOS_SIGNING_IDENTITY contains characters that are unsafe in Xcode settings' >&2
  exit 1
fi
[[ "$IOS_SIGNING_CERTIFICATE_SHA256" =~ ^[0-9A-F]{64}$ ]] || {
  echo 'IOS_SIGNING_CERTIFICATE_SHA256 must be the canonical uppercase 64-hexadecimal certificate fingerprint' >&2
  exit 1
}

decode_base64() {
  local name="$1"
  local value="$2"
  local output="$3"
  if ! printf '%s' "$value" |
    INPUT_NAME="$name" python3 -c '
import base64
import os
import sys

name = os.environ["INPUT_NAME"]
payload = b"".join(sys.stdin.buffer.read().split())
try:
    decoded = base64.b64decode(payload, validate=True)
except Exception as error:
    raise SystemExit(f"{name} is invalid: {error}")
if not decoded:
    raise SystemExit(f"{name} decoded to an empty file")
sys.stdout.buffer.write(decoded)
' > "$output"; then
    rm -f -- "$output"
    return 1
  fi
}

certificate_path="$SIGNING_TEMP_DIRECTORY/camellia-remote-ios-signing.p12"
profile_path="$SIGNING_TEMP_DIRECTORY/camellia-remote-ios.mobileprovision"
umask 077
decode_base64 IOS_CERTIFICATE_BASE64 "$IOS_CERTIFICATE_BASE64" "$certificate_path"
if ! decode_base64 IOS_PROVISIONING_PROFILE_BASE64 \
  "$IOS_PROVISIONING_PROFILE_BASE64" "$profile_path"; then
  rm -f -- "$certificate_path"
  exit 1
fi

{
  echo 'IOS_NATIVE_SIGNING=signed'
  echo 'IOS_DISTRIBUTION_TRUST=platform-key'
  echo 'IOS_ARTIFACT_SUFFIX='
  echo "IOS_CERTIFICATE_PATH=$certificate_path"
  echo "IOS_PROVISIONING_PROFILE_PATH=$profile_path"
} >> "$SIGNING_ENV_FILE"
echo "iOS native signing enabled for $IOS_EXPORT_METHOD distribution"

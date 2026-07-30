#!/usr/bin/env bash
set -euo pipefail

: "${SIGNING_ENV_FILE:?SIGNING_ENV_FILE is required}"
: "${SIGNING_TEMP_DIRECTORY:?SIGNING_TEMP_DIRECTORY is required}"
[[ -d "$SIGNING_TEMP_DIRECTORY" ]] || {
  echo 'SIGNING_TEMP_DIRECTORY is not a directory' >&2
  exit 2
}

signing_values=(
  ANDROID_SIGNING_KEY
  ANDROID_KEY_STORE_PASSWORD
  ANDROID_KEY_PASSWORD
  ANDROID_ALIAS
  ANDROID_SIGNING_CERTIFICATE_SHA256
)
signing_count=0
for name in "${signing_values[@]}"; do
  [[ -z "${!name:-}" ]] || signing_count=$((signing_count + 1))
done
[[ "$signing_count" == 0 || "$signing_count" == 5 ]] || {
  echo 'ANDROID_SIGNING_KEY, ANDROID_KEY_STORE_PASSWORD, ANDROID_KEY_PASSWORD, ANDROID_ALIAS and ANDROID_SIGNING_CERTIFICATE_SHA256 must be configured together' >&2
  exit 1
}

if [[ "$signing_count" == 0 ]]; then
  {
    echo 'ANDROID_NATIVE_SIGNING=unsigned'
    echo 'ANDROID_ARTIFACT_SUFFIX=-unsigned'
  } >> "$SIGNING_ENV_FILE"
  echo 'Android APK/AAB will be explicit unsigned re-signing inputs'
  exit 0
fi

[[ "$ANDROID_ALIAS" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || {
  echo 'ANDROID_ALIAS contains unsupported characters' >&2
  exit 1
}
[[ "$ANDROID_SIGNING_CERTIFICATE_SHA256" =~ ^[0-9A-F]{64}$ ]] || {
  echo 'ANDROID_SIGNING_CERTIFICATE_SHA256 must be the canonical uppercase 64-hexadecimal certificate fingerprint' >&2
  exit 1
}
command -v keytool >/dev/null 2>&1 || {
  echo 'keytool is required to validate the Android release keystore' >&2
  exit 127
}

keystore_path="$SIGNING_TEMP_DIRECTORY/camellia-remote-android-release.keystore"
umask 077
if ! printf '%s' "$ANDROID_SIGNING_KEY" |
  python3 -c '
import base64
import sys

payload = b"".join(sys.stdin.buffer.read().split())
try:
    decoded = base64.b64decode(payload, validate=True)
except Exception as error:
    raise SystemExit(f"ANDROID_SIGNING_KEY is invalid: {error}")
if not decoded:
    raise SystemExit("ANDROID_SIGNING_KEY decoded to an empty file")
sys.stdout.buffer.write(decoded)
' > "$keystore_path"; then
  rm -f -- "$keystore_path"
  exit 1
fi

export ANDROID_KEY_STORE_PASSWORD ANDROID_ALIAS
certificate_output="$(
  keytool -J-Duser.language=en -list -v \
    -keystore "$keystore_path" \
    -storepass:env ANDROID_KEY_STORE_PASSWORD \
    -alias "$ANDROID_ALIAS"
)" || {
  rm -f -- "$keystore_path"
  echo 'Android keystore password or alias validation failed' >&2
  exit 1
}
certificate_sha256="$(
  sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' <<< "$certificate_output" |
    tr -d ':[:space:]' |
    tr '[:lower:]' '[:upper:]' |
    head -n 1
)"
[[ "$certificate_sha256" =~ ^[0-9A-F]{64}$ ]] || {
  rm -f -- "$keystore_path"
  echo 'Could not resolve the Android signing certificate SHA-256 digest' >&2
  exit 1
}
[[ "$certificate_sha256" == "$ANDROID_SIGNING_CERTIFICATE_SHA256" ]] || {
  rm -f -- "$keystore_path"
  echo 'The Android keystore does not match ANDROID_SIGNING_CERTIFICATE_SHA256' >&2
  exit 1
}

{
  echo 'ANDROID_NATIVE_SIGNING=signed'
  echo 'ANDROID_ARTIFACT_SUFFIX='
  echo "CAMELLIA_ANDROID_STORE_FILE=$keystore_path"
  echo "CAMELLIA_ANDROID_KEY_ALIAS=$ANDROID_ALIAS"
  echo "ANDROID_SIGNING_IDENTITY=$certificate_sha256"
} >> "$SIGNING_ENV_FILE"
echo "Android release signing enabled with certificate SHA-256 $certificate_sha256"

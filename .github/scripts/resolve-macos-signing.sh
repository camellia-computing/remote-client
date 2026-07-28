#!/usr/bin/env bash
set -euo pipefail

: "${SIGNING_ENV_FILE:?SIGNING_ENV_FILE is required}"
: "${SIGNING_TEMP_DIRECTORY:?SIGNING_TEMP_DIRECTORY is required}"
[[ -d "$SIGNING_TEMP_DIRECTORY" ]] || {
  echo 'SIGNING_TEMP_DIRECTORY is not a directory' >&2
  exit 2
}

signing_values=(
  APPLE_CERTIFICATE
  APPLE_CERTIFICATE_PASSWORD
  APPLE_SIGNING_IDENTITY
  APPLE_SIGNING_TRUST_MODE
)
notary_values=(APPLE_API_ISSUER APPLE_API_KEY APPLE_API_PRIVATE_KEY)
signing_count=0
notary_count=0
for name in "${signing_values[@]}"; do
  [[ -z "${!name:-}" ]] || signing_count=$((signing_count + 1))
done
for name in "${notary_values[@]}"; do
  [[ -z "${!name:-}" ]] || notary_count=$((notary_count + 1))
done

if [[ "${APPLE_SIGNING_IDENTITY:-}" == - ]]; then
  [[ "$signing_count" == 1 && "$notary_count" == 0 ]] || {
    echo 'Ad-hoc signing uses APPLE_SIGNING_IDENTITY=- without certificate, trust-mode, or notarization values' >&2
    exit 1
  }
  {
    echo 'MACOS_NATIVE_SIGNING=ad-hoc'
    echo 'MACOS_DISTRIBUTION_TRUST=none'
  } >> "$SIGNING_ENV_FILE"
  echo 'macOS ad-hoc signing enabled'
  exit 0
fi

[[ "$signing_count" == 0 || "$signing_count" == 4 ]] || {
  echo 'APPLE_CERTIFICATE, APPLE_CERTIFICATE_PASSWORD, APPLE_SIGNING_IDENTITY and APPLE_SIGNING_TRUST_MODE must be configured together' >&2
  exit 1
}
[[ "$notary_count" == 0 || "$notary_count" == 3 ]] || {
  echo 'APPLE_API_ISSUER, APPLE_API_KEY and APPLE_API_PRIVATE_KEY must be configured together' >&2
  exit 1
}
[[ "$notary_count" == 0 || "$signing_count" == 4 ]] || {
  echo 'macOS notarization requires a complete signing configuration' >&2
  exit 1
}

if [[ "$signing_count" == 0 ]]; then
  {
    echo 'MACOS_NATIVE_SIGNING=ad-hoc'
    echo 'MACOS_DISTRIBUTION_TRUST=none'
  } >> "$SIGNING_ENV_FILE"
  echo 'macOS package will retain the project ad-hoc signature'
  exit 0
fi

case "$APPLE_SIGNING_TRUST_MODE" in
  private-trust|public-trust) ;;
  *)
    echo 'APPLE_SIGNING_TRUST_MODE must be private-trust or public-trust' >&2
    exit 1
    ;;
esac

if [[ "$notary_count" == 3 ]]; then
  [[ "$APPLE_SIGNING_TRUST_MODE" == public-trust ]] || {
    echo 'Apple notarization is available only with APPLE_SIGNING_TRUST_MODE=public-trust' >&2
    exit 1
  }
  [[ "$APPLE_API_ISSUER" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
    echo 'APPLE_API_ISSUER must be a canonical UUID' >&2
    exit 1
  }
  [[ "$APPLE_API_KEY" =~ ^[A-Z0-9]{10}$ ]] || {
    echo 'APPLE_API_KEY must be a 10-character App Store Connect key ID' >&2
    exit 1
  }
  [[ "$APPLE_API_PRIVATE_KEY" == *'BEGIN PRIVATE KEY'* && \
     "$APPLE_API_PRIVATE_KEY" == *'END PRIVATE KEY'* ]] || {
    echo 'APPLE_API_PRIVATE_KEY is not a PEM private key' >&2
    exit 1
  }
fi

certificate_path="$SIGNING_TEMP_DIRECTORY/camellia-remote-macos-signing.p12"
umask 077
if ! printf '%s' "$APPLE_CERTIFICATE" |
  python3 -c '
import base64
import sys

payload = b"".join(sys.stdin.buffer.read().split())
try:
    decoded = base64.b64decode(payload, validate=True)
except Exception as error:
    raise SystemExit(f"APPLE_CERTIFICATE is invalid: {error}")
if not decoded:
    raise SystemExit("APPLE_CERTIFICATE decoded to an empty file")
sys.stdout.buffer.write(decoded)
' > "$certificate_path"; then
  rm -f -- "$certificate_path"
  exit 1
fi

native_signing=signed
{
  echo "MACOS_CERTIFICATE_PATH=$certificate_path"
  echo "MACOS_DISTRIBUTION_TRUST=$APPLE_SIGNING_TRUST_MODE"
  echo "MACOS_SIGNING_IDENTITY=$APPLE_SIGNING_IDENTITY"
} >> "$SIGNING_ENV_FILE"

if [[ "$notary_count" == 3 ]]; then
  api_key_path="$SIGNING_TEMP_DIRECTORY/AuthKey_$APPLE_API_KEY.p8"
  printf '%s\n' "$APPLE_API_PRIVATE_KEY" > "$api_key_path"
  {
    echo "APPLE_API_KEY_PATH=$api_key_path"
    echo "APPLE_API_ISSUER=$APPLE_API_ISSUER"
    echo "APPLE_API_KEY=$APPLE_API_KEY"
  } >> "$SIGNING_ENV_FILE"
  native_signing=notarized
fi
echo "MACOS_NATIVE_SIGNING=$native_signing" >> "$SIGNING_ENV_FILE"
echo "macOS native signing mode resolved to $native_signing ($APPLE_SIGNING_TRUST_MODE)"

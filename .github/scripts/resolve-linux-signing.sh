#!/usr/bin/env bash
set -euo pipefail

: "${SIGNING_ENV_FILE:?SIGNING_ENV_FILE is required}"

signing_values=(LINUX_GPG_FINGERPRINT LINUX_GPG_PRIVATE_KEY LINUX_GPG_PASSPHRASE)
signing_count=0
for name in "${signing_values[@]}"; do
  [[ -z "${!name:-}" ]] || signing_count=$((signing_count + 1))
done
[[ "$signing_count" == 0 || "$signing_count" == 3 ]] || {
  echo 'LINUX_GPG_FINGERPRINT, LINUX_GPG_PRIVATE_KEY and LINUX_GPG_PASSPHRASE must be configured together' >&2
  exit 1
}

if [[ "$signing_count" == 0 ]]; then
  echo 'ARTIFACT_SIGNING=none' >> "$SIGNING_ENV_FILE"
  echo 'Linux packages will not receive additional OpenPGP signatures'
  exit 0
fi

fingerprint="${LINUX_GPG_FINGERPRINT//[[:space:]]/}"
fingerprint="${fingerprint^^}"
[[ "$fingerprint" =~ ^[0-9A-F]+$ && ( ${#fingerprint} -eq 40 || ${#fingerprint} -eq 64 ) ]] || {
  echo 'LINUX_GPG_FINGERPRINT must be a full 40- or 64-hexadecimal fingerprint' >&2
  exit 1
}
[[ "$LINUX_GPG_PRIVATE_KEY" == *'BEGIN PGP PRIVATE KEY BLOCK'* && \
   "$LINUX_GPG_PRIVATE_KEY" == *'END PGP PRIVATE KEY BLOCK'* ]] || {
  echo 'LINUX_GPG_PRIVATE_KEY must be an ASCII-armored OpenPGP private key' >&2
  exit 1
}
{
  echo 'ARTIFACT_SIGNING=openpgp-detached'
  echo "LINUX_GPG_FINGERPRINT=$fingerprint"
} >> "$SIGNING_ENV_FILE"
echo 'Linux OpenPGP artifact signing enabled'

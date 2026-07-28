#!/usr/bin/env bash
set -euo pipefail

: "${LINUX_GPG_FINGERPRINT:?LINUX_GPG_FINGERPRINT is required}"
: "${LINUX_GPG_PUBLIC_KEY:?LINUX_GPG_PUBLIC_KEY is required}"
[[ "$#" -gt 0 ]] || { echo 'At least one Linux artifact is required' >&2; exit 2; }
command -v gpg >/dev/null 2>&1 || { echo 'gpg is required for Linux OpenPGP verification' >&2; exit 127; }

fingerprint="${LINUX_GPG_FINGERPRINT//[[:space:]]/}"
fingerprint="${fingerprint^^}"
[[ "$fingerprint" =~ ^[0-9A-F]+$ && ( ${#fingerprint} -eq 40 || ${#fingerprint} -eq 64 ) ]] || {
  echo 'LINUX_GPG_FINGERPRINT must be a full fingerprint' >&2
  exit 2
}
[[ -f "$LINUX_GPG_PUBLIC_KEY" && ! -L "$LINUX_GPG_PUBLIC_KEY" ]] || {
  echo 'The Linux OpenPGP public key is unavailable' >&2
  exit 2
}

verify_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/camellia-remote-linux-verification.XXXXXX")"
trap 'rm -rf -- "$verify_root"' EXIT
mkdir -m 700 "$verify_root/keyring"
GNUPGHOME="$verify_root/keyring" gpg --batch --quiet \
  --import "$LINUX_GPG_PUBLIC_KEY" >/dev/null 2>&1
if ! GNUPGHOME="$verify_root/keyring" gpg --batch --with-colons --with-fingerprint \
  --list-keys "$fingerprint" 2>/dev/null |
  awk -F: -v expected="$fingerprint" \
    '$1 == "fpr" && toupper($10) == expected { found = 1 } END { exit !found }'; then
  echo 'The Linux OpenPGP public key does not match the recorded fingerprint' >&2
  exit 1
fi

for artifact in "$@"; do
  signature="$artifact.asc"
  [[ -f "$artifact" && ! -L "$artifact" && -f "$signature" && ! -L "$signature" ]] || {
    echo "Linux artifact or detached signature is unavailable: $artifact" >&2
    exit 2
  }
  GNUPGHOME="$verify_root/keyring" gpg --batch --status-fd 1 \
    --verify "$signature" "$artifact" 2>/dev/null |
    awk -v expected="$fingerprint" '
      $1 == "[GNUPG:]" && $2 == "VALIDSIG" && toupper($3) == expected { valid = 1 }
      END { exit !valid }
    ' || {
      echo "Linux OpenPGP signature verification failed: $artifact" >&2
      exit 1
    }
done

printf 'Linux OpenPGP artifact set verified with %s\n' "$fingerprint"

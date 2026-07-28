#!/usr/bin/env bash
set -euo pipefail

: "${LINUX_GPG_FINGERPRINT:?LINUX_GPG_FINGERPRINT is required}"
: "${LINUX_GPG_PRIVATE_KEY:?LINUX_GPG_PRIVATE_KEY is required}"
: "${LINUX_GPG_PASSPHRASE:?LINUX_GPG_PASSPHRASE is required}"
: "${LINUX_GPG_PUBLIC_KEY_OUTPUT:?LINUX_GPG_PUBLIC_KEY_OUTPUT is required}"

[[ "$#" -gt 0 ]] || { echo 'At least one Linux artifact is required' >&2; exit 2; }
command -v gpg >/dev/null 2>&1 || { echo 'gpg is required for Linux OpenPGP signing' >&2; exit 127; }

fingerprint="${LINUX_GPG_FINGERPRINT//[[:space:]]/}"
fingerprint="${fingerprint^^}"
[[ "$fingerprint" =~ ^[0-9A-F]+$ && ( ${#fingerprint} -eq 40 || ${#fingerprint} -eq 64 ) ]] || {
  echo 'LINUX_GPG_FINGERPRINT must be a full 40- or 64-hexadecimal fingerprint' >&2
  exit 2
}

for artifact in "$@"; do
  [[ -f "$artifact" && ! -L "$artifact" ]] || {
    echo "Linux signing input is not a regular file: $artifact" >&2
    exit 2
  }
done

signing_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/camellia-remote-linux-signing.XXXXXX")"
trap 'rm -rf -- "$signing_root"' EXIT
signing_home="$signing_root/signing"
verify_home="$signing_root/verify"
private_key="$signing_root/private-key.asc"
passphrase_file="$signing_root/passphrase"
mkdir -m 700 "$signing_home" "$verify_home"
umask 077
printf '%s\n' "$LINUX_GPG_PRIVATE_KEY" > "$private_key"
printf '%s' "$LINUX_GPG_PASSPHRASE" > "$passphrase_file"

GNUPGHOME="$signing_home" gpg --batch --quiet --import "$private_key" >/dev/null 2>&1 || {
  echo 'The Linux OpenPGP private key could not be imported' >&2
  exit 1
}
if ! GNUPGHOME="$signing_home" gpg --batch --with-colons --with-fingerprint \
  --list-secret-keys "$fingerprint" 2>/dev/null |
  awk -F: -v expected="$fingerprint" \
    '$1 == "fpr" && toupper($10) == expected { found = 1 } END { exit !found }'; then
  echo 'The configured Linux signing fingerprint does not identify an imported secret key' >&2
  exit 1
fi

public_key="$LINUX_GPG_PUBLIC_KEY_OUTPUT"
[[ ! -e "$public_key" || ( -f "$public_key" && ! -L "$public_key" ) ]] || {
  echo 'The Linux OpenPGP public-key output is not a regular file' >&2
  exit 2
}
mkdir -p "$(dirname "$public_key")"
GNUPGHOME="$signing_home" gpg --batch --armor --export "$fingerprint" > "$public_key"
[[ -s "$public_key" ]] || { echo 'The Linux OpenPGP public key could not be exported' >&2; exit 1; }
GNUPGHOME="$verify_home" gpg --batch --quiet --import "$public_key" >/dev/null 2>&1

for artifact in "$@"; do
  signature="$artifact.asc"
  [[ ! -e "$signature" || ( -f "$signature" && ! -L "$signature" ) ]] || {
    echo "The Linux signature output is not a regular file: $signature" >&2
    exit 2
  }
  GNUPGHOME="$signing_home" gpg --batch --yes --pinentry-mode loopback \
    --passphrase-file "$passphrase_file" --local-user "$fingerprint!" \
    --armor --detach-sign --output "$signature" "$artifact"
  GNUPGHOME="$verify_home" gpg --batch --status-fd 1 \
    --verify "$signature" "$artifact" 2>/dev/null |
    awk -v expected="$fingerprint" '
      $1 == "[GNUPG:]" && $2 == "VALIDSIG" && toupper($3) == expected { valid = 1 }
      END { exit !valid }
    ' || {
      echo "Linux OpenPGP signature verification failed: $artifact" >&2
      exit 1
    }
done

printf 'Linux OpenPGP signatures verified with %s\n' "$fingerprint"

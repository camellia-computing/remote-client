#!/usr/bin/env bash
set -euo pipefail

repository="$(cd "$(dirname "$0")/../../.." && pwd)"
test_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/camellia-remote-signing-tests.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

macos_env="$test_root/macos.env"
SIGNING_ENV_FILE="$macos_env" SIGNING_TEMP_DIRECTORY="$test_root" \
  bash "$repository/.github/scripts/resolve-macos-signing.sh" >/dev/null
grep -Fqx 'MACOS_NATIVE_SIGNING=ad-hoc' "$macos_env"
grep -Fqx 'MACOS_DISTRIBUTION_TRUST=none' "$macos_env"

if APPLE_CERTIFICATE=partial SIGNING_ENV_FILE="$macos_env" \
  SIGNING_TEMP_DIRECTORY="$test_root" \
  bash "$repository/.github/scripts/resolve-macos-signing.sh" >/dev/null 2>&1; then
  echo 'partial macOS signing configuration unexpectedly succeeded' >&2
  exit 1
fi

macos_password='test-only-password'
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$test_root/macos.key" \
  -out "$test_root/macos.crt" \
  -subj '/CN=Camellia Remote macOS Test' \
  -days 1 >/dev/null 2>&1
openssl pkcs12 -export \
  -inkey "$test_root/macos.key" \
  -in "$test_root/macos.crt" \
  -out "$test_root/macos.p12" \
  -passout "pass:$macos_password" >/dev/null 2>&1
macos_certificate="$(base64 -w 0 "$test_root/macos.p12")"
macos_sha256="$(
  openssl x509 -in "$test_root/macos.crt" -outform DER |
    shasum -a 256 |
    awk '{ print toupper($1) }'
)"
: > "$macos_env"
APPLE_CERTIFICATE="$macos_certificate" \
APPLE_CERTIFICATE_PASSWORD="$macos_password" \
APPLE_SIGNING_CERTIFICATE_SHA256="$macos_sha256" \
APPLE_SIGNING_IDENTITY='Camellia Remote macOS Test' \
APPLE_SIGNING_TRUST_MODE=private-trust \
SIGNING_ENV_FILE="$macos_env" \
SIGNING_TEMP_DIRECTORY="$test_root" \
  bash "$repository/.github/scripts/resolve-macos-signing.sh" >/dev/null
grep -Fqx 'MACOS_NATIVE_SIGNING=signed' "$macos_env"
grep -Fqx "MACOS_SIGNING_CERTIFICATE_SHA256=$macos_sha256" "$macos_env"

ios_env="$test_root/ios.env"
SIGNING_ENV_FILE="$ios_env" SIGNING_TEMP_DIRECTORY="$test_root" \
  bash "$repository/.github/scripts/resolve-ios-signing.sh" >/dev/null
grep -Fqx 'IOS_NATIVE_SIGNING=unsigned' "$ios_env"
grep -Fqx 'IOS_ARTIFACT_SUFFIX=-unsigned' "$ios_env"

if IOS_TEAM_ID=partial SIGNING_ENV_FILE="$ios_env" \
  SIGNING_TEMP_DIRECTORY="$test_root" \
  bash "$repository/.github/scripts/resolve-ios-signing.sh" >/dev/null 2>&1; then
  echo 'partial iOS signing configuration unexpectedly succeeded' >&2
  exit 1
fi

IOS_CERTIFICATE_BASE64=dGVzdC1jZXJ0aWZpY2F0ZQ== \
IOS_CERTIFICATE_PASSWORD=test-only-password \
IOS_PROVISIONING_PROFILE_BASE64=dGVzdC1wcm9maWxl \
IOS_SIGNING_CERTIFICATE_SHA256="$(printf 'A%.0s' {1..64})" \
IOS_SIGNING_IDENTITY='Apple Distribution: Camellia Test (A1B2C3D4E5)' \
IOS_TEAM_ID=A1B2C3D4E5 \
IOS_EXPORT_METHOD=app-store-connect \
SIGNING_ENV_FILE="$ios_env" \
SIGNING_TEMP_DIRECTORY="$test_root" \
  bash "$repository/.github/scripts/resolve-ios-signing.sh" >/dev/null
grep -Fqx 'IOS_NATIVE_SIGNING=signed' "$ios_env"
grep -Fqx 'IOS_DISTRIBUTION_TRUST=platform-key' "$ios_env"

android_env="$test_root/android.env"
SIGNING_ENV_FILE="$android_env" SIGNING_TEMP_DIRECTORY="$test_root" \
  bash "$repository/.github/scripts/resolve-android-signing.sh" >/dev/null
grep -Fqx 'ANDROID_NATIVE_SIGNING=unsigned' "$android_env"
grep -Fqx 'ANDROID_ARTIFACT_SUFFIX=-unsigned' "$android_env"

if ANDROID_ALIAS=partial SIGNING_ENV_FILE="$android_env" \
  SIGNING_TEMP_DIRECTORY="$test_root" \
  bash "$repository/.github/scripts/resolve-android-signing.sh" >/dev/null 2>&1; then
  echo 'partial Android signing configuration unexpectedly succeeded' >&2
  exit 1
fi

if command -v keytool >/dev/null 2>&1; then
  android_keystore="$test_root/android-release.p12"
  android_password='test-only-password'
  keytool -genkeypair \
    -alias release \
    -keyalg RSA \
    -keysize 2048 \
    -validity 1 \
    -dname 'CN=Camellia Remote Test,O=Camellia Computing' \
    -keystore "$android_keystore" \
    -storetype PKCS12 \
    -storepass "$android_password" \
    -keypass "$android_password" \
    >/dev/null 2>&1
  android_keystore_base64="$(base64 -w 0 "$android_keystore")"
  android_certificate_sha256="$(
    keytool -J-Duser.language=en -list -v \
      -keystore "$android_keystore" \
      -storepass "$android_password" \
      -alias release |
      sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' |
      tr -d ':[:space:]' |
      tr '[:lower:]' '[:upper:]' |
      head -n 1
  )"
  ANDROID_SIGNING_KEY="$android_keystore_base64" \
  ANDROID_KEY_STORE_PASSWORD="$android_password" \
  ANDROID_KEY_PASSWORD="$android_password" \
  ANDROID_ALIAS=release \
  ANDROID_SIGNING_CERTIFICATE_SHA256="$android_certificate_sha256" \
  SIGNING_ENV_FILE="$android_env" \
  SIGNING_TEMP_DIRECTORY="$test_root" \
    bash "$repository/.github/scripts/resolve-android-signing.sh" >/dev/null
  grep -Fqx 'ANDROID_NATIVE_SIGNING=signed' "$android_env"
  grep -Eq '^ANDROID_SIGNING_IDENTITY=[0-9A-F]{64}$' "$android_env"
fi

linux_env="$test_root/linux.env"
SIGNING_ENV_FILE="$linux_env" \
  bash "$repository/.github/scripts/resolve-linux-signing.sh" >/dev/null
grep -Fqx 'ARTIFACT_SIGNING=none' "$linux_env"
if LINUX_GPG_FINGERPRINT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
  SIGNING_ENV_FILE="$linux_env" \
  bash "$repository/.github/scripts/resolve-linux-signing.sh" >/dev/null 2>&1; then
  echo 'partial Linux signing configuration unexpectedly succeeded' >&2
  exit 1
fi

export GNUPGHOME="$test_root/gpg-source"
mkdir -m 700 "$GNUPGHOME"
passphrase='test-only-passphrase'
gpg --batch --pinentry-mode loopback --passphrase "$passphrase" \
  --quick-generate-key 'Camellia Remote Test <test@example.invalid>' ed25519 sign 1d \
  >/dev/null 2>&1
fingerprint="$(
  gpg --batch --with-colons --list-secret-keys |
    awk -F: '$1 == "fpr" { print $10; exit }'
)"
private_key="$(
  gpg --batch --pinentry-mode loopback --passphrase "$passphrase" \
    --armor --export-secret-keys "$fingerprint"
)"
public_key="$test_root/public.asc"
artifact="$test_root/artifact.tar.gz"
printf 'artifact\n' > "$artifact"

LINUX_GPG_FINGERPRINT="$fingerprint" \
LINUX_GPG_PRIVATE_KEY="$private_key" \
LINUX_GPG_PASSPHRASE="$passphrase" \
SIGNING_ENV_FILE="$linux_env" \
  bash "$repository/.github/scripts/resolve-linux-signing.sh" >/dev/null
LINUX_GPG_FINGERPRINT="$fingerprint" \
LINUX_GPG_PRIVATE_KEY="$private_key" \
LINUX_GPG_PASSPHRASE="$passphrase" \
LINUX_GPG_PUBLIC_KEY_OUTPUT="$public_key" \
  bash "$repository/.github/scripts/linux-openpgp-sign.sh" "$artifact" >/dev/null
LINUX_GPG_FINGERPRINT="$fingerprint" LINUX_GPG_PUBLIC_KEY="$public_key" \
  bash "$repository/.github/scripts/linux-openpgp-verify.sh" "$artifact" >/dev/null

printf 'tamper\n' >> "$artifact"
if LINUX_GPG_FINGERPRINT="$fingerprint" LINUX_GPG_PUBLIC_KEY="$public_key" \
  bash "$repository/.github/scripts/linux-openpgp-verify.sh" "$artifact" >/dev/null 2>&1; then
  echo 'tampered Linux artifact unexpectedly verified' >&2
  exit 1
fi

echo 'Cross-platform release signing resolver tests passed'

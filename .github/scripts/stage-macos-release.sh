#!/usr/bin/env bash
set -euo pipefail

: "${MACOS_DISTRIBUTION_TRUST:?MACOS_DISTRIBUTION_TRUST is required}"
: "${MACOS_NATIVE_SIGNING:?MACOS_NATIVE_SIGNING is required}"
: "${RELEASE_VERSION:?RELEASE_VERSION is required}"

[[ $# -eq 2 ]] || {
  echo "usage: $0 APP_BUNDLE OUTPUT_DIRECTORY" >&2
  exit 2
}
app_bundle=$1
output_directory=$2
[[ -d "$app_bundle" && ! -L "$app_bundle" && "$app_bundle" == *.app ]] || {
  echo "macOS application bundle is invalid: $app_bundle" >&2
  exit 2
}
mkdir -p "$output_directory"

case "$MACOS_NATIVE_SIGNING:$MACOS_DISTRIBUTION_TRUST" in
  ad-hoc:none|signed:private-trust|signed:public-trust|notarized:public-trust) ;;
  *)
    echo "Invalid macOS signing state: $MACOS_NATIVE_SIGNING/$MACOS_DISTRIBUTION_TRUST" >&2
    exit 1
    ;;
esac

if [[ "$MACOS_NATIVE_SIGNING" == signed || "$MACOS_NATIVE_SIGNING" == notarized ]]; then
  : "${MACOS_SIGNING_IDENTITY:?MACOS_SIGNING_IDENTITY is required}"
  sign_arguments=(
    --force
    --deep
    --options runtime
    '--preserve-metadata=identifier,entitlements,requirements'
    --sign "$MACOS_SIGNING_IDENTITY"
  )
  if [[ "$MACOS_DISTRIBUTION_TRUST" == public-trust ]]; then
    sign_arguments+=(--timestamp)
  else
    sign_arguments+=(--timestamp=none)
  fi
  codesign "${sign_arguments[@]}" "$app_bundle"
fi

codesign --verify --deep --strict --verbose=2 "$app_bundle"
if [[ "$MACOS_NATIVE_SIGNING" == signed || "$MACOS_NATIVE_SIGNING" == notarized ]]; then
  signature_details="$(codesign --display --verbose=4 "$app_bundle" 2>&1)"
  grep -F "Authority=$MACOS_SIGNING_IDENTITY" <<< "$signature_details" >/dev/null || {
    echo 'The staged macOS app signer does not match MACOS_SIGNING_IDENTITY' >&2
    exit 1
  }
fi

staging_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/camellia-remote-macos-stage.XXXXXX")"
trap 'rm -rf -- "$staging_root"' EXIT
zip_path="$output_directory/camellia-remote-$RELEASE_VERSION-macos-universal.zip"
dmg_path="$output_directory/camellia-remote-$RELEASE_VERSION-macos-universal.dmg"

if [[ "$MACOS_NATIVE_SIGNING" == notarized ]]; then
  : "${APPLE_API_ISSUER:?APPLE_API_ISSUER is required}"
  : "${APPLE_API_KEY:?APPLE_API_KEY is required}"
  : "${APPLE_API_KEY_PATH:?APPLE_API_KEY_PATH is required}"
  submission_zip="$staging_root/notary-submission.zip"
  ditto -c -k --keepParent "$app_bundle" "$submission_zip"
  xcrun notarytool submit "$submission_zip" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY" \
    --issuer "$APPLE_API_ISSUER" \
    --wait
  xcrun stapler staple "$app_bundle"
  xcrun stapler validate "$app_bundle"
  spctl --assess --type execute --verbose=2 "$app_bundle"
fi

ditto -c -k --keepParent "$app_bundle" "$zip_path"
dmg_root="$staging_root/dmg"
mkdir -p "$dmg_root"
cp -R "$app_bundle" "$dmg_root/"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
  -volname 'Camellia Remote' \
  -srcfolder "$dmg_root" \
  -ov \
  -format UDZO \
  "$dmg_path"

if [[ "$MACOS_NATIVE_SIGNING" == signed || "$MACOS_NATIVE_SIGNING" == notarized ]]; then
  dmg_sign_arguments=(--force --sign "$MACOS_SIGNING_IDENTITY")
  if [[ "$MACOS_DISTRIBUTION_TRUST" == public-trust ]]; then
    dmg_sign_arguments+=(--timestamp)
  else
    dmg_sign_arguments+=(--timestamp=none)
  fi
  codesign "${dmg_sign_arguments[@]}" "$dmg_path"
  codesign --verify --strict --verbose=2 "$dmg_path"
fi

if [[ "$MACOS_NATIVE_SIGNING" == notarized ]]; then
  xcrun notarytool submit "$dmg_path" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY" \
    --issuer "$APPLE_API_ISSUER" \
    --wait
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
fi

echo "Staged macOS release as $MACOS_NATIVE_SIGNING ($MACOS_DISTRIBUTION_TRUST)"

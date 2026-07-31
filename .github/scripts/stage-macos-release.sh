#!/usr/bin/env bash
set -euo pipefail

: "${MACOS_DISTRIBUTION_TRUST:?MACOS_DISTRIBUTION_TRUST is required}"
: "${MACOS_NATIVE_SIGNING:?MACOS_NATIVE_SIGNING is required}"
: "${RELEASE_VERSION:?RELEASE_VERSION is required}"

[[ $# -eq 2 ]] || {
  echo "usage: $0 BUILD_PRODUCTS_DIRECTORY OUTPUT_DIRECTORY" >&2
  exit 2
}
build_products_directory=$1
output_directory=$2
[[ -d "$build_products_directory" && ! -L "$build_products_directory" ]] || {
  echo "macOS build products directory is invalid: $build_products_directory" >&2
  exit 2
}

shopt -s nullglob
app_bundles=("$build_products_directory"/*.app)
shopt -u nullglob
if ((${#app_bundles[@]} != 1)); then
  echo "Expected exactly one macOS application bundle, found ${#app_bundles[@]}" >&2
  exit 1
fi
app_bundle="${app_bundles[0]}"
[[ -d "$app_bundle" && ! -L "$app_bundle" ]] || {
  echo "macOS application bundle is invalid: $app_bundle" >&2
  exit 2
}
mkdir -p "$output_directory"

case "$MACOS_NATIVE_SIGNING:$MACOS_DISTRIBUTION_TRUST" in
  ad-hoc:none|signed:derive|signed:private-trust|signed:public-trust|notarized:public-trust) ;;
  *)
    echo "Invalid macOS signing state: $MACOS_NATIVE_SIGNING/$MACOS_DISTRIBUTION_TRUST" >&2
    exit 1
    ;;
esac

if [[ "$MACOS_NATIVE_SIGNING" == signed || "$MACOS_NATIVE_SIGNING" == notarized ]]; then
  : "${MACOS_SIGNING_CERTIFICATE_SHA256:?MACOS_SIGNING_CERTIFICATE_SHA256 is required}"
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
  certificate_directory="$(mktemp -d "${RUNNER_TEMP:-/tmp}/camellia-remote-macos-certificates.XXXXXX")"
  certificate_prefix="$certificate_directory/codesign"
  codesign -d --extract-certificates "$certificate_prefix" "$app_bundle"
  [[ -f "${certificate_prefix}0" ]] || {
    echo 'codesign did not expose the final app signing certificate' >&2
    exit 1
  }
  actual_certificate_sha256="$(
    shasum -a 256 "${certificate_prefix}0" | awk '{ print toupper($1) }'
  )"
  [[ "$actual_certificate_sha256" == "$MACOS_SIGNING_CERTIFICATE_SHA256" ]] || {
    echo 'Final macOS app certificate differs from the reviewed P12 identity' >&2
    exit 1
  }
  if security verify-cert -p codeSign -c "${certificate_prefix}0" >/dev/null 2>&1; then
    actual_trust=public-trust
  else
    actual_trust=private-trust
  fi
  rm -rf -- "$certificate_directory"
  if [[ "$MACOS_DISTRIBUTION_TRUST" == derive ]]; then
    MACOS_DISTRIBUTION_TRUST="$actual_trust"
    export MACOS_DISTRIBUTION_TRUST
    [[ -n "${GITHUB_ENV:-}" ]] || {
      echo 'GITHUB_ENV is required to preserve derived macOS trust' >&2
      exit 1
    }
    echo "MACOS_DISTRIBUTION_TRUST=$actual_trust" >> "$GITHUB_ENV"
  elif [[ "$MACOS_DISTRIBUTION_TRUST" != "$actual_trust" ]]; then
    echo "macOS trust changed from $MACOS_DISTRIBUTION_TRUST to $actual_trust" >&2
    exit 1
  fi
  if [[ "$MACOS_DISTRIBUTION_TRUST" == public-trust ]]; then
    grep -F 'Timestamp=' <<< "$signature_details" >/dev/null || {
      echo 'Public-trust macOS application signature has no secure timestamp' >&2
      exit 1
    }
  fi
fi

staging_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/camellia-remote-macos-stage.XXXXXX")"
trap 'rm -rf -- "$staging_root"' EXIT
zip_path="$output_directory/camellia-remote-$RELEASE_VERSION-macos-universal.zip"
dmg_path="$output_directory/camellia-remote-$RELEASE_VERSION-macos-universal.dmg"

if [[ "$MACOS_NATIVE_SIGNING" == notarized ]]; then
  [[ "$MACOS_DISTRIBUTION_TRUST" == public-trust ]] || {
    echo 'Notarization requires native public trust' >&2
    exit 1
  }
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
  dmg_signature_details="$(codesign --display --verbose=4 "$dmg_path" 2>&1)"
  grep -F "Authority=$MACOS_SIGNING_IDENTITY" <<< "$dmg_signature_details" >/dev/null || {
    echo 'The staged macOS disk image signer does not match MACOS_SIGNING_IDENTITY' >&2
    exit 1
  }
  if [[ "$MACOS_DISTRIBUTION_TRUST" == public-trust ]]; then
    grep -F 'Timestamp=' <<< "$dmg_signature_details" >/dev/null || {
      echo 'Public-trust macOS disk image signature has no secure timestamp' >&2
      exit 1
    }
  fi
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

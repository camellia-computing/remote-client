#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${IOS_NATIVE_SIGNING:?IOS_NATIVE_SIGNING is required}"
: "${IOS_ARTIFACT_SUFFIX:?IOS_ARTIFACT_SUFFIX is required}"
: "${IOS_BUNDLE_ID:?IOS_BUNDLE_ID is required}"
version="${1:?version is required}"
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]{0,127}$ ]] || {
  echo 'version contains unsupported characters' >&2
  exit 2
}
if [[ "$IOS_NATIVE_SIGNING" == signed ]]; then
  [[ -z "$IOS_ARTIFACT_SUFFIX" ]] || {
    echo "Signed iOS artifacts must not use a filename suffix" >&2
    exit 2
  }
elif [[ "$IOS_NATIVE_SIGNING" == unsigned ]]; then
  [[ "$IOS_ARTIFACT_SUFFIX" == -unsigned ]] || {
    echo "Unsigned iOS artifacts must use the -unsigned filename suffix" >&2
    exit 2
  }
else
  echo "Unsupported IOS_NATIVE_SIGNING mode: $IOS_NATIVE_SIGNING" >&2
  exit 2
fi

flutter_directory="$GITHUB_WORKSPACE/flutter"
artifact_directory="$GITHUB_WORKSPACE/artifacts"
mkdir -p "$artifact_directory"

shopt -s nullglob
archives=("$flutter_directory"/build/ios/archive/*.xcarchive)
if ((${#archives[@]} != 1)); then
  echo "Expected exactly one iOS xcarchive, found ${#archives[@]}" >&2
  exit 1
fi
archive="${archives[0]}"
archive_output="$artifact_directory/camellia-remote-${version}-ios${IOS_ARTIFACT_SUFFIX}-xcarchive.zip"
ditto -c -k --keepParent "$archive" "$archive_output"

if [[ "$IOS_NATIVE_SIGNING" == signed ]]; then
  : "${IOS_PROFILE_UUID:?IOS_PROFILE_UUID is required}"
  : "${IOS_TEAM_ID:?IOS_TEAM_ID is required}"
  : "${IOS_EXPORT_METHOD:?IOS_EXPORT_METHOD is required}"
  : "${IOS_SIGNING_IDENTITY:?IOS_SIGNING_IDENTITY is required}"
  : "${IOS_SIGNING_IDENTITY_SHA256:?IOS_SIGNING_IDENTITY_SHA256 is required}"
  ipa_candidates=("$flutter_directory"/build/ios/ipa/*.ipa)
  if ((${#ipa_candidates[@]} != 1)); then
    echo "Expected exactly one signed IPA, found ${#ipa_candidates[@]}" >&2
    exit 1
  fi
  ipa_output="$artifact_directory/camellia-remote-${version}-ios.ipa"
  cp "${ipa_candidates[0]}" "$ipa_output"

  verification_root="$RUNNER_TEMP/camellia-remote-ios-verification"
  rm -rf -- "$verification_root"
  mkdir -p "$verification_root"
  ditto -x -k "$ipa_output" "$verification_root"
  apps=("$verification_root"/Payload/*.app)
  if ((${#apps[@]} != 1)); then
    echo "Expected exactly one application in the signed IPA, found ${#apps[@]}" >&2
    exit 1
  fi
  app="${apps[0]}"
  codesign --verify --deep --strict --verbose=2 "$app"
  signature_details="$(codesign -dvvv "$app" 2>&1)"
  grep -Fqx "Authority=$IOS_SIGNING_IDENTITY" <<< "$signature_details" || {
    echo 'Signed iOS app authority does not match IOS_SIGNING_IDENTITY' >&2
    exit 1
  }
  grep -Fqx "TeamIdentifier=$IOS_TEAM_ID" <<< "$signature_details" || {
    echo 'Signed iOS app TeamIdentifier does not match IOS_TEAM_ID' >&2
    exit 1
  }

  embedded_profile="$app/embedded.mobileprovision"
  [[ -f "$embedded_profile" && ! -L "$embedded_profile" ]] || {
    echo 'Signed iOS app does not contain an embedded provisioning profile' >&2
    exit 1
  }
  embedded_profile_plist="$verification_root/embedded-profile.plist"
  security cms -D -i "$embedded_profile" > "$embedded_profile_plist"
  python3 "$GITHUB_WORKSPACE/.github/scripts/ios_profile.py" validate \
    --profile-plist "$embedded_profile_plist" \
    --bundle-id "$IOS_BUNDLE_ID" \
    --team-id "$IOS_TEAM_ID" \
    --export-method "$IOS_EXPORT_METHOD" \
    --certificate-sha256 "$IOS_SIGNING_IDENTITY_SHA256"
  embedded_uuid="$(
    /usr/libexec/PlistBuddy -c 'Print :UUID' "$embedded_profile_plist"
  )"
  embedded_uuid_upper="$(tr '[:lower:]' '[:upper:]' <<< "$embedded_uuid")"
  [[ "$embedded_uuid_upper" == "$IOS_PROFILE_UUID" ]] || {
    echo 'Signed iOS app contains an unexpected provisioning profile UUID' >&2
    exit 1
  }

  entitlements_plist="$verification_root/app-entitlements.plist"
  codesign -d --entitlements :- "$app" > "$entitlements_plist" 2>/dev/null
  python3 "$GITHUB_WORKSPACE/.github/scripts/ios_profile.py" verify-app \
    --info-plist "$app/Info.plist" \
    --entitlements-plist "$entitlements_plist" \
    --bundle-id "$IOS_BUNDLE_ID" \
    --team-id "$IOS_TEAM_ID" \
    --export-method "$IOS_EXPORT_METHOD"
else
  apps=("$archive"/Products/Applications/*.app)
  if ((${#apps[@]} != 1)); then
    echo "Expected exactly one unsigned application, found ${#apps[@]}" >&2
    exit 1
  fi
  app="${apps[0]}"
  if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
    echo 'Unsigned iOS re-signing input unexpectedly has a valid app signature' >&2
    exit 1
  fi
  ipa_root="$RUNNER_TEMP/camellia-remote-unsigned-ipa"
  rm -rf -- "$ipa_root"
  mkdir -p "$ipa_root/Payload"
  cp -R "$app" "$ipa_root/Payload/"
  (
    cd "$ipa_root"
    zip -qry \
      "$artifact_directory/camellia-remote-${version}-ios-unsigned.ipa" \
      Payload
  )
fi

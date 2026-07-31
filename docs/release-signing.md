# Release signing modes

Camellia Remote treats supply-chain evidence and operating-system publisher
signing as separate controls. Every formal release receives SHA-256 checksums,
an immutable source/version manifest, organization release evidence, and
GitHub/Sigstore attestations. Platform-native certificates are optional where
the documented output is explicitly restricted or a re-signing input.

The release workflow always builds the complete supported platform matrix,
records it in `versions.json`, publishes `NATIVE-SIGNING.md`, and emits the
effective category for every file in `release-evidence.json`. A partial
credential group fails before packaging.

Credential selection is deterministic: a complete verified public-trust group
has the highest distribution trust, followed by a complete private-trust or
platform-key group. Linux OpenPGP is recorded as private distribution trust.
When no complete group exists, the workflow does not guess: macOS is ad-hoc,
desktop/Linux output is restricted unsigned, and Android/iOS output is an
explicit re-signing input. Web native signing is not applicable.

## Canonical configuration source

Do not hand-transcribe certificate fingerprints, base64 payloads, or password
values from an old release ticket. Organization-owned signing tools generate a
protected local `github-actions/` bundle with the exact variable and Secret
names consumed below. Its `metadata.json` is review material, `variables.env`
contains non-secret configuration, and `secrets/` is uploaded without printing
payloads.

Use the relevant generator or Apple preparation command from the organization
artifact-signing baseline,
then deliberately apply it only to this repository:

The `scripts/...` commands later in this document are run from a checked-out
organization policy repository, not from this client repository.

```bash
./github-actions/upload.sh --apply --repo <owner>/<remote-client-repository>
```

```powershell
pwsh -NoProfile -File .\github-actions\Upload.ps1 -Apply `
  -Repository <owner>/<remote-client-repository>
```

The generated configuration is not an approval or registration event. Update
the public registry through review, then validate the configuration on a
protected release branch before promotion. Never commit the generated
directory or paste a Secret payload into chat.

## Result when no native credentials are configured

| Platform | Output |
| --- | --- |
| Windows | Unsigned ZIP, portable EXE, and MSI; checksums and attestations remain present |
| macOS | Ad-hoc-signed app in ZIP/DMG; no publisher identity or notarization |
| Linux | Unsigned tar/DEB/AppImage plus checksums and attestations; no detached OpenPGP signature |
| Android | `-unsigned.apk` and `-unsigned.aab` re-signing inputs; the formal workflow never falls back to the debug keystore |
| iOS | Unsigned `-unsigned-xcarchive.zip` and `-unsigned.ipa` re-signing inputs |
| Web | Deployment archives; native signing is not applicable |

Unsigned Android/iOS outputs are not installable public releases. Sign and
provision them through the selected store or managed-distribution channel.

## Windows Authenticode

Configure one complete group in the mapped client repository. The workflow
validates both groups, rejects any partial group, and selects the first complete
group in this fixed order:

1. primary: `WINDOWS_CODESIGN_*`;
2. secondary: the corresponding `WINDOWS_SECONDARY_CODESIGN_*` names.

The primary group contains:

- variable `WINDOWS_CODESIGN_CERTIFICATE_SHA256`: the canonical uppercase
  64-hexadecimal SHA-256 leaf fingerprint recorded in the organization signing
  registry;
- variable `WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT`: the complete uppercase
  40-hexadecimal SHA-1 leaf thumbprint recorded in the organization signing
  registry;
- secret `WINDOWS_CODESIGN_PFX_BASE64`;
- secret `WINDOWS_CODESIGN_PFX_PASSWORD`;
- optional variable `WINDOWS_TIMESTAMP_URL` (the workflow defaults to
  `http://timestamp.digicert.com`).

The secondary group replaces `WINDOWS_` with `WINDOWS_SECONDARY_` for the
certificate variables and PFX secrets. It is a rotation/fallback group, not a
second signer.

For a managed-device private hierarchy, run the organization Windows generator
with PowerShell 7.6 or later. It writes the public certificate information and
the exact two Variables plus two Secret payloads into `github-actions/`:

```powershell
pwsh -NoProfile -File .\scripts\New-CamelliaWindowsPrivateCodeSigningCertificate.ps1 `
  -OutputDirectory C:\Secure\camellia-windows-signing
```

Review `camellia-private-code-signing-identity.json` and
`github-actions\variables.env`, then use the generated upload helper from the
canonical configuration section. A privately generated chain is expected to
resolve as `private-trust`; a publicly trusted certificate must resolve as
`public-trust` through native Authenticode verification.

The PFX must contain exactly one current certificate with a private key and the
code-signing extended key usage. Its derived canonical SHA-256 fingerprint and
Windows-native SHA-1 thumbprint must equal both reviewed variables, so a secret
rotation cannot silently publish under an unreviewed identity. The workflow
signs the Camellia application, owned native library, portable wrapper, and MSI
before creating the ZIP. It requires that exact thumbprint and an RFC 3161
timestamp on every signed file. It then derives `public-trust` from a valid
native chain or `private-trust` from an otherwise intact signature whose root
is not trusted by the clean runner. No configured label can promote a
certificate.

Install only the public private-CA root on managed test endpoints. A private
root does not establish SmartScreen reputation or public trust.

## macOS signing and notarization

Certificate signing uses the same ordered-group rule as Windows: a complete
primary group wins, otherwise the complete secondary group is used; any partial
group fails the release. The primary signing group is:

- secret `APPLE_CERTIFICATE`: one-line base64 of the P12;
- secret `APPLE_CERTIFICATE_PASSWORD`;
- variable `APPLE_SIGNING_CERTIFICATE_SHA256`: canonical uppercase
  64-hexadecimal leaf fingerprint;
- variable `APPLE_SIGNING_IDENTITY`: the exact code-signing identity.

Its optional notarization extension additionally requires:

- variable `APPLE_API_ISSUER`;
- variable `APPLE_API_KEY`;
- secret `APPLE_API_PRIVATE_KEY`.

The secondary group uses the corresponding `APPLE_SECONDARY_*` names, including
its own optional notarization extension. The workflow records the selected
group, derives trust with the native code-signing verifier, imports the P12 into
an ephemeral keychain, signs the app and DMG, verifies the exact final leaf,
and removes the P12/keychain in an always-run cleanup step. Notarization is
accepted only when the selected certificate resolves to `public-trust`; the
workflow then submits and staples the app and final DMG and runs Gatekeeper
assessment.

A private CA is valid for controlled devices that trust its public root, but it
cannot obtain Apple notarization. Public downloads should use a current
Developer ID Application identity and notarization.

For either a private test P12 or an Apple-issued Developer ID P12, use the
organization tool to calculate the exact leaf SHA-256 and emit the matching
bundle rather than manually encoding the P12:

```bash
bash scripts/prepare-camellia-apple-signing-bundle.sh macos \
  "$HOME/Secure/camellia-macos-signing" \
  /controlled-inputs/developer-id.p12 \
  'Developer ID Application: Camellia Computing (TEAMID)' \
  public-trust
```

The hosted macOS job remains the authority that imports the P12 into an
ephemeral keychain and verifies `APPLE_SIGNING_IDENTITY`. Keep notarization API
credentials separate; configure them only for a mature public-trust Developer
ID release, never for the private test hierarchy.

To request intentional ad-hoc mode explicitly, set only:

```bash
gh variable set APPLE_SIGNING_IDENTITY \
  --repo <owner>/<remote-client-repository> \
  --body '-'
```

Leaving all Apple values absent has the same ad-hoc result because the current
macOS project is structurally ad-hoc signed.

## Linux OpenPGP artifact signatures

Configure all three values or leave all three absent:

- variable `LINUX_GPG_FINGERPRINT`: complete 40- or 64-hexadecimal signing-key
  fingerprint;
- secret `LINUX_GPG_PRIVATE_KEY`: ASCII-armored secret-key/subkey export;
- secret `LINUX_GPG_PASSPHRASE`.

Generate the offline primary key and signing subkey through the organization
tool, which creates the exact `LINUX_GPG_*` bundle:

```bash
bash scripts/new-camellia-linux-openpgp-key.sh \
  "$HOME/Secure/camellia-linux-signing" \
  'Camellia Computing Release <release@example.invalid>'
```

Review the printed signing-subkey fingerprint and public identity metadata;
then use the generated uploader. The private subkey export and passphrase are
not release artifacts or backups, even though the uploader can transfer them to
the selected GitHub Actions scope.

The workflow creates and independently verifies one detached `.asc` signature
per tar/DEB/AppImage plus an architecture-specific public-key asset. Publish the
full fingerprint through a separate authenticated channel; a key downloaded
beside its own signature is not independently trusted.

## Android release identity

Configure the complete group:

- secret `ANDROID_SIGNING_KEY`: one-line base64 of the release keystore;
- secret `ANDROID_KEY_STORE_PASSWORD`;
- secret `ANDROID_KEY_PASSWORD`;
- secret `ANDROID_ALIAS`.
- variable `ANDROID_SIGNING_CERTIFICATE_SHA256`: canonical uppercase
  64-hexadecimal update-certificate fingerprint.

These names match the source repository's existing secret inventory, but the
new workflow fixes the old gap: merely storing the secrets is insufficient.
The former workflow never passed them to Gradle and silently used the debug
keystore. Formal Camellia Remote builds now consume and verify the complete
group or produce explicitly unsigned re-signing inputs.

For a fresh application/update lineage, the organization generator creates a
PKCS#12 keystore, public identity JSON, and the exact Android bundle:

```bash
bash scripts/new-camellia-android-release-keystore.sh \
  "$HOME/Secure/camellia-android-signing"
```

The new-key generator is not a substitute for the historical update key. If
the package has ever been installed under an existing signing certificate,
retrieve and re-upload that original reviewed keystore instead. GitHub cannot
reveal legacy source-fork Secret values, so do not generate a replacement and
claim update continuity. For this pre-launch product, choose a new identity
only after explicitly confirming that no update lineage needs the old key.

When the original controlled keystore is available, use the organization
preparation command to validate it and create the exact GitHub Actions group
without modifying the historical key:

```bash
bash scripts/prepare-camellia-android-release-keystore.sh \
  "$HOME/Secure/camellia-android-existing-update-key" \
  /controlled-inputs/original-release.keystore \
  original-release-alias
```

Review the resulting public identity JSON, `github-actions/metadata.json`, and
`github-actions/variables.env`, then use its PowerShell 7 or Bash uploader with
the single mapped client-repository scope. The prepared
bundle supports historical JKS and PKCS#12 stores, including distinct JKS store
and key passwords; its SHA-256 value is the one the release workflow and the
organization registry must both verify. Preserve the original offline backup
before uploading anything.

The workflow validates the alias and certificate, builds without the debug-key
fallback, verifies the APK/AAB signatures, and records the full certificate
SHA-256 digest. Back up the keystore and credentials separately: this key is the
application update identity.

## iOS and iPadOS signing

Configure the complete, iOS-specific group:

- secret `IOS_CERTIFICATE_BASE64`: one-line base64 of the P12 containing the
  Apple distribution or development identity;
- secret `IOS_CERTIFICATE_PASSWORD`;
- secret `IOS_PROVISIONING_PROFILE_BASE64`: one-line base64 of the matching
  `.mobileprovision`;
- variable `IOS_SIGNING_CERTIFICATE_SHA256`: canonical uppercase
  64-hexadecimal leaf fingerprint;
- variable `IOS_SIGNING_IDENTITY`: exact identity name shown by
  `security find-identity -v -p codesigning`;
- variable `IOS_TEAM_ID`: the 10-character Apple Developer Team ID;
- variable `IOS_EXPORT_METHOD`: one of `app-store-connect`,
  `release-testing`, `debugging`, or `enterprise`.

Prepare the P12 and matching profile as one group through the organization
tool; it calculates the P12 fingerprint and creates every required `IOS_*`
value without printing the profile or P12 payload:

```bash
bash scripts/prepare-camellia-apple-signing-bundle.sh ios \
  "$HOME/Secure/camellia-ios-signing" \
  /controlled-inputs/camellia-remote-ios.p12 \
  /controlled-inputs/camellia-remote.mobileprovision \
  'Apple Distribution: Camellia Computing (TEAMID)' \
  TEAMID \
  release-testing
```

This only packages an already-issued Apple identity and profile. The hosted
macOS workflow independently authorizes the profile's certificate, Team ID,
bundle ID, distribution type and entitlements; a generated bundle is not proof
that an Apple account or profile is ready for public distribution.

The workflow imports the P12 into an ephemeral keychain, verifies that the
profile is current, explicitly targets `com.camellia.remote`, matches the Team
ID and selected distribution type, and authorizes the exact certificate. It
generates manual Xcode export options, signs and exports the IPA, then verifies
the final bundle signature, authority, Team ID, embedded profile, bundle ID and
entitlements. The keychain, profile, P12 and generated Xcode settings are
removed by an always-run cleanup step.

The four methods mean:

| Value | Required profile | Intended output |
| --- | --- | --- |
| `app-store-connect` | App Store Connect distribution | Upload to App Store Connect |
| `release-testing` | Ad Hoc profile with registered devices | Controlled device testing |
| `debugging` | Development profile with registered devices | Development/testing only |
| `enterprise` | In-house profile from an eligible enterprise account | Managed enterprise distribution |

The iOS group is independent from the macOS Developer ID group. If the complete
iOS group is absent, the workflow retains explicit `unsigned` filenames and
`re-signing-input` metadata. A partial group, expired profile, wrong bundle,
wrong Team ID, wrong profile type, or certificate/profile mismatch fails before
publication.

## Public identity synchronization

Private keys, keystores, PFX/P12 files, passwords and provisioning profiles are
never copied into Git repositories. Shared desktop publisher material should be
held as organization secrets scoped only to the client repositories that
consume it. Non-secret identities—certificate thumbprints, Apple identity/Team
ID, OpenPGP fingerprint, Android certificate SHA-256, trust classification and
validity/rotation state—belong in the organization signing registry and the
machine-readable metadata produced by each release.

Repository documentation must link to the organization policy rather than
forking its own stale copy. A certificate rotation is complete only when the
secret group, public identity registry, workflow verification and affected
repository documentation all agree.

## Rotation and verification

- Rotate each credential group atomically; a half-rotated group blocks release.
- Never generate a production private key inside GitHub Actions.
- Revoke/distrust a compromised identity before uploading its replacement.
- Download the published asset and verify checksum, attestation, native
  signature, exact identity, installation, upgrade, rollback, and uninstall on
  the target platform.
- A release with an unexpected signing mode remains a no-go. Do not re-sign or
  relabel already-published immutable bytes.

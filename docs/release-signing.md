# Release signing modes

Camellia Remote treats supply-chain evidence and operating-system publisher
signing as separate controls. Every formal release receives SHA-256 checksums,
an immutable source/version manifest, and GitHub/Sigstore attestations.
Platform-native certificates are optional while the product is pre-launch.

The release workflow records every selected platform in `versions.json` and
publishes `NATIVE-SIGNING.md`. A partial signing group fails before packaging.
Candidate runs (`publish=false`) never receive repository signing secrets,
regardless of which values are configured.

## Result when no native credentials are configured

| Platform | Output |
| --- | --- |
| Windows | Unsigned ZIP, portable EXE, and MSI; checksums and attestations remain present |
| macOS | Ad-hoc-signed app in ZIP/DMG; no publisher identity or notarization |
| Linux | Unsigned tar/DEB/AppImage plus checksums and attestations; no detached OpenPGP signature |
| Android | `-unsigned.apk` and `-unsigned.aab` re-signing inputs; the formal workflow never falls back to the debug keystore |
| iOS | Unsigned xcarchive and `-unsigned.ipa` re-signing inputs |
| Web | Deployment archives; native signing is not applicable |

Unsigned Android/iOS outputs are not installable public releases. Sign and
provision them through the selected store or managed-distribution channel.

## Windows Authenticode

Configure the complete group in `camellia-computing/remote-client`:

- secret `WINDOWS_CODESIGN_PFX_BASE64`;
- secret `WINDOWS_CODESIGN_PFX_PASSWORD`;
- variable `WINDOWS_SIGNING_TRUST_MODE`, exactly `private-trust` or
  `public-trust`;
- optional variable `WINDOWS_TIMESTAMP_URL` (the workflow defaults to
  `http://timestamp.digicert.com`).

Example using PowerShell 7.6 or later:

```powershell
$repository = 'camellia-computing/remote-client'
[Convert]::ToBase64String(
  [IO.File]::ReadAllBytes((Resolve-Path '.\camellia-code-signing.pfx'))
) | gh secret set WINDOWS_CODESIGN_PFX_BASE64 --repo $repository
gh secret set WINDOWS_CODESIGN_PFX_PASSWORD --repo $repository
gh variable set WINDOWS_SIGNING_TRUST_MODE `
  --repo $repository `
  --body 'private-trust'
```

The PFX must contain exactly one current certificate with a private key and the
code-signing extended key usage. The workflow signs the Camellia application,
owned native library, portable wrapper, and MSI before creating the ZIP. It
requires the exact PFX thumbprint and an RFC 3161 timestamp on every signed
file. `public-trust` additionally requires normal Windows trust validation;
`private-trust` permits an otherwise-valid chain whose root is not installed on
the ephemeral runner.

Install only the public private-CA root on managed test endpoints. A private
root does not establish SmartScreen reputation or public trust.

## macOS signing and notarization

Certificate signing requires the complete group:

- secret `APPLE_CERTIFICATE`: one-line base64 of the P12;
- secret `APPLE_CERTIFICATE_PASSWORD`;
- variable `APPLE_SIGNING_IDENTITY`: the exact code-signing identity;
- variable `APPLE_SIGNING_TRUST_MODE`: `private-trust` or `public-trust`.

Notarization additionally requires:

- variable `APPLE_API_ISSUER`;
- variable `APPLE_API_KEY`;
- secret `APPLE_API_PRIVATE_KEY`.

The notarization group is accepted only with `public-trust`. The workflow
imports the P12 into an ephemeral keychain, signs the app and DMG, verifies the
exact identity, and removes the P12/keychain in an always-run cleanup step.
When notarization is configured, it submits and staples the app and final DMG
and runs Gatekeeper assessment.

A private CA is valid for controlled devices that trust its public root, but it
cannot obtain Apple notarization. Public downloads should use a current
Developer ID Application identity and notarization.

To request intentional ad-hoc mode explicitly, set only:

```bash
gh variable set APPLE_SIGNING_IDENTITY \
  --repo camellia-computing/remote-client \
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

```bash
repository=camellia-computing/remote-client
gh variable set LINUX_GPG_FINGERPRINT \
  --repo "$repository" \
  --body '<full-signing-fingerprint>'
gh secret set LINUX_GPG_PRIVATE_KEY \
  --repo "$repository" \
  < linux-release-private.asc
gh secret set LINUX_GPG_PASSPHRASE --repo "$repository"
```

The workflow creates and independently verifies one detached `.asc` signature
per tar/DEB/AppImage plus an architecture-specific public-key asset. Publish the
full fingerprint through a separate authenticated channel; a key downloaded
beside its own signature is not independently trusted.

## Android release identity

Configure the complete group:

- secret `ANDROID_KEYSTORE_BASE64`;
- secret `ANDROID_KEYSTORE_PASSWORD`;
- secret `ANDROID_KEY_PASSWORD`;
- variable `ANDROID_KEY_ALIAS`.

```bash
repository=camellia-computing/remote-client
base64 < android-release.keystore | tr -d '\n' |
  gh secret set ANDROID_KEYSTORE_BASE64 --repo "$repository"
gh secret set ANDROID_KEYSTORE_PASSWORD --repo "$repository"
gh secret set ANDROID_KEY_PASSWORD --repo "$repository"
gh variable set ANDROID_KEY_ALIAS --repo "$repository" --body '<release-alias>'
```

The workflow validates the alias and certificate, builds without the debug-key
fallback, verifies the APK/AAB signatures, and records the full certificate
SHA-256 digest. Back up the keystore and credentials separately: this key is the
application update identity.

## iOS status

The current workflow deliberately supports only unsigned re-signing inputs. It
does not accept iOS certificate/profile secrets yet, and filenames retain
`unsigned`. Before an installable release, add a dedicated signing/export path
with a distribution/development certificate, provisioning profile, matching
entitlements, and reviewed export method. Do not reuse the macOS P12 group by
assumption.

## Rotation and verification

- Rotate each credential group atomically; a half-rotated group blocks release.
- Never generate a production private key inside GitHub Actions.
- Revoke/distrust a compromised identity before uploading its replacement.
- Download the published asset and verify checksum, attestation, native
  signature, exact identity, installation, upgrade, rollback, and uninstall on
  the target platform.
- A release with an unexpected signing mode remains a no-go. Do not re-sign or
  relabel already-published immutable bytes.

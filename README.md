# Camellia Remote Client

Secure cross-platform remote desktop software for Windows, macOS, Linux, Android, iOS, and Web. The Rust core owns transport, capture, input, clipboard, file transfer, and session security; Flutter provides the user interface.

Use Camellia Remote only on systems you own or are explicitly authorized to administer. Remote access without informed authorization can violate law and privacy.

## Product topology

- [`remote-protocol`](https://github.com/camellia-computing/remote-protocol): shared wire types, transport helpers, limits, and cryptographic configuration. This repository pins it as a submodule.
- [`remote-server`](https://github.com/camellia-computing/remote-server): identity/rendezvous and relay services.
- [`remote-management-server`](https://github.com/camellia-computing/remote-management-server): accounts, devices, policy, audit, plugin signing, and the commit-pinned Web client.

All four repositories start from clean root histories. Camellia Remote is prelaunch: only the current application identifiers and data layout are supported; obsolete development-build data is not migrated. Protocol parsing that remains in the runtime is a network safety/interoperability boundary, not a local data-compatibility promise.

## Development

Validated toolchains are Rust 1.93.0, Flutter 3.44.5, Node.js 24.18.0, and the locked package managers/dependencies in this repository. Apple CI and release builds use the `macos-26` hosted image with Xcode 26.2 selected through `DEVELOPER_DIR`; the workflow fails if that exact Xcode installation or its iPhoneOS/macOS SDKs are unavailable. Platform builds also require the native SDK, compiler, and vcpkg dependencies declared by CI.
The current Apple deployment baselines are iOS 13.0 and macOS 10.15. The
Apple Silicon slice uses its architecture floor, macOS 11.0, while the
x86_64 slice preserves the 10.15 product baseline. Rust, Flutter/Xcode,
CocoaPods, FFmpeg, and vcpkg derive their applicable minimum from this policy.
If a locked plugin requires a newer OS, raise the relevant baseline everywhere;
the required CI policy check rejects partial drift.

```bash
git submodule update --init --recursive
bash .github/scripts/prepare-dependencies.sh locked
bash .github/scripts/generate-bridge.sh
cargo check --workspace --all-targets --locked
cd flutter
flutter pub get
flutter analyze --no-fatal-infos
flutter test
```

Windows automation uses current PowerShell Core (`pwsh`), never Windows PowerShell. Packaging and signing commands must run under PowerShell 7.6+.

Useful component paths:

- `src/client.rs`, `src/server/`: peer and hosted-session behavior.
- `src/platform/`: OS integration and privilege boundaries.
- `libs/scrap`, `libs/enigo`, `libs/clipboard`: capture, input, and clipboard.
- `flutter/`: desktop, mobile, and Web interface.
- `.github/scripts/release_metadata.py`: the canonical release metadata validator.

## Security and data handling

- Pairing, session, file-transfer, clipboard, input, and proxy inputs are bounded and validated before resource allocation or filesystem access.
- Secrets and deployment endpoints must be supplied through the documented build/deployment trust channel; never commit private keys, access tokens, or customer configuration.
- Desktop application data uses the `com.camellia.remote` identity. No old application directory is scanned or migrated.
- Auto-update accepts only the Camellia Computing repository/artifact allow-list and release integrity metadata.
- Web assets embedded by the management server are accepted only from the full commit in `web-client.lock` after a successful client push CI run.

Report vulnerabilities through GitHub private vulnerability reporting as described in [SECURITY.md](SECURITY.md).

## CI and release

Pull requests and `main` run pinned-action checks for metadata, dependencies, Rust, Flutter, Web, scripts, and platform-specific build contracts. The Apple required gate compiles both the iOS Rust library and a complete unsigned iOS archive, then rejects tracked or untracked build-time mutation of the checked-out source tree. Apple plugin resolution uses exactly CocoaPods 1.17.0 with committed iOS and macOS locks; project-level Swift Package Manager integration remains explicitly disabled until every plugin provides an immutable package graph. Xcode inherits plugin linkage from CocoaPods instead of hard-coding plugin frameworks, generated bridge sources are formatted before reuse, and the iOS host uses an application-owned C ABI link anchor instead of depending on a generated header that may validly be empty. The release workflow accepts only an exact commit reachable from the default branch and reuses artifacts from its successful full default-branch CI run: either the matching push run or a maintainer-dispatched matching CI run that executes every runtime, automation, and dependency gate.
Required CI also rejects any mismatch between the protocol submodule and the exact revision recorded in `SOURCE_PROVENANCE.json`.

Formal publication requires the protected `release` environment. Selected platform packages are produced once, checksummed, described by `versions.json`, and attested with GitHub/Sigstore identity. Windows Authenticode, macOS signing/notarization, Linux OpenPGP signatures, Android release keys, and iOS certificate/provisioning exports are optional complete groups; missing groups produce explicitly unsigned/ad-hoc or re-signing outputs and partial groups fail closed. Public packages should use a recognized publisher identity, but private or temporarily unsigned releases remain supported when their limitations are stated. See [release signing modes](docs/release-signing.md).

Versions are stable SemVer from the root manifest. Published tags and assets are immutable; rebuilding or moving an existing release is prohibited. See the [release policy](docs/releasing.md) and [production-readiness audit](docs/production-readiness-audit.md) for the complete release decision.

## Self-hosting

Deploy the server and management repositories by immutable OCI digest, configure TLS ingress, generate independent high-entropy server/device secrets, and keep database and service keys in encrypted backups. The initial target is single-region 99.9%, RPO ≤ 1 hour, and RTO ≤ 4 hours; those objectives require monitored hourly backups and tested restores, not only source configuration.

Client builds should inject only reviewed identity/relay/API origins and the matching server public key. A production HTTPS Web client must use WSS endpoints on the same trusted origin or an explicitly reviewed origin.

## License and provenance

This repository is licensed under GNU AGPL-3.0-only. Deploying a modified version over a network carries corresponding-source obligations. The exact imported snapshot, normalized repository, and protocol revision are recorded in [SOURCE_PROVENANCE.json](SOURCE_PROVENANCE.json); upstream RustDesk and other third-party copyright and license terms remain applicable as described in [NOTICE](NOTICE).

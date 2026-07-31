# Release policy

Remote Client has one automated stable-release state machine. It follows the
organization CI/CD, evidence, and artifact-signing policies without embedding
an organization or physical repository name.

## State machine

1. A successful `main` CI starts Release Manager.
2. The Release App computes the next stable SemVer from conventional commits,
   updates only the reviewed version/changelog fields, and opens
   `release/next`.
3. The exact PR head must pass `CI / Required` and receive a current-head human
   approval from a writer or administrator. Change requests block promotion.
4. The App SHA-guards a squash merge, verifies the resulting push CI, and
   prepares the exact draft Release and lightweight tag.
5. The tag starts `publish-release.yml`. Manual dispatch only recovers an
   existing managed tag from trusted `main` control code.
6. Every formal draft builds the complete support matrix once: Windows x64 and
   ARM64, macOS universal, Linux x64 and ARM64, Android ARM64, iOS, and Web.
   Formal builds disable mutable Flutter, package-manager, vcpkg, and Rust
   caches; ordinary CI retains reviewed caches for throughput.
7. One job rejects missing, duplicate, nested, symlinked, empty, cross-attempt,
   or unclaimed artifacts; aggregates native-signing status; creates SPDX SBOM,
   provenance, organization `release-evidence.json`, and final checksums; and
   freezes the candidate for seven days.
8. The protected `release` environment is reached only after all builds and
   evidence succeed. Publication reauthorizes the exact Release PR and CI,
   signs every raw Release asset with keyless Sigstore, uploads through the App,
   downloads every byte, verifies checksums/evidence/signatures, and requires
   immutable state.
9. Completion and `latest` are reconciled to the highest completed stable
   version. A successful client release then opens or verifies a Management PR
   that changes only `web-client.lock`; Management CI and human review still
   control that merge.

The first formal release is `v1.0.0`. Version, source, platform selection, and
publication mode are not operator inputs. A rerun may resume only the same
App-authored draft or read-only verify an immutable Release. Fixes always use a
new version.

## Evidence and native trust

`release-evidence.json` identifies every distributable file, checksum, size,
platform/architecture, SBOM, provenance, and explicit native-signing category.
Trust priority is:

1. verified public-trust platform identity;
2. verified private-trust or platform-key identity;
3. verified OpenPGP/private distribution identity;
4. ad-hoc or unsigned restricted output;
5. unsigned Android/iOS re-signing input.

The workflow never labels missing credentials as signed. Web signing is
explicitly not applicable. Every mode still receives immutable checksums,
provenance, and workflow-bound Sigstore bundles. See
[release signing modes](release-signing.md) for credential groups and rotation.

## GitHub App and review contract

Hosted configuration provides the Release App client ID/login/private key, the
protected `release` environment, and the complete logical
`REMOTE_REPOSITORY_MAP`. The App is installed on the client repository and, for
the post-release lock PR, the mapped Management repository. It receives only
the per-job Contents, Pull requests, Issues, Metadata, and Administration
permissions declared by the workflows—never Actions or Workflows write access.

GitHub exposes the complete repository merge-policy fields only to a caller
with push access. The hosted-policy check therefore uses a separate,
repository-scoped App token with short-lived Contents write permission. That
token is not reused for release authorization; the authorization controller
uses the job token constrained to Contents, Actions, and pull-request read.

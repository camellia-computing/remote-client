# Release policy

Camellia Remote publication follows the organization
[CI/CD baseline](https://github.com/camellia-computing/.github/blob/main/docs/CI_CD_BASELINE.md)
and
[artifact-signing policy](https://github.com/camellia-computing/.github/blob/main/docs/ARTIFACT_SIGNING.md).
The client version, source commit and generated Flutter/Rust bridge are bound to
one successful full default-branch CI run before any native package starts. The
accepted run is either the exact `push` CI or a maintainer-dispatched exact
`workflow_dispatch` CI; the latter deliberately enables every runtime and
automation/dependency gate. In both cases the Release workflow requires the one unexpired,
commit-named bridge artifact before packaging.

## Candidate and formal modes

`Release` is manually dispatchable so maintainers can validate any commit that
is reachable from the default branch:

- `publish=false` is a non-publishing candidate. It never receives native
  signing or Release App secrets, creates no tag or Release, and uploads only
  short-lived Actions artifacts plus their keyless GitHub/Sigstore
  attestations.
- `publish=true` is accepted only from the default-branch workflow definition.
  It validates the Release App identity, repository merge policy and immutable
  Releases, then waits for a non-self reviewer in the protected `release`
  environment.

Every selected platform builds once on its owning runner. Internal artifact
names bind every package to one workflow run attempt, so a partial rerun cannot
silently mix old and new outputs. After all selected builds succeed, the
workflow:

1. rejects missing, unexpected, nested, symlinked, empty, or duplicate platform
   artifact inputs;
2. verifies that every native asset is claimed by exactly one platform signing
   record;
3. aggregates `versions.json` and `NATIVE-SIGNING.md`;
4. generates an SPDX JSON SBOM with the commit-pinned Anchore action and pinned
   Syft version;
5. computes `SHA256SUMS`, attests that exact inventory with GitHub/Sigstore,
   preserves the provenance bundle, recomputes the final checksum inventory,
   and verifies every byte; and
6. uploads one
   `candidate-assets-<version>-<commit>-run-<run-id>-<attempt>` artifact for
   seven days.

The consolidated artifact is produced for both candidate and formal modes.
Use it—not individual platform artifacts—for review, native testing, signing
status inspection, SBOM review, and Go/No-Go evidence. If any build job must be
rerun, rerun all jobs so every selected platform belongs to the same attempt.

Formal publication downloads and reverifies that same consolidated candidate;
it does not reassemble platform outputs. The Release App then creates a draft
for the exact commit. Automation downloads every draft asset, compares it
byte-for-byte with the candidate, verifies `SHA256SUMS`, publishes the draft,
waits for immutable state, downloads the public asset set again and repeats
verification. An incompatible draft, tag, asset, author, commit, signer, or
non-convergent API state fails closed.

## GitHub App contract

Formal publication requires:

| Resource | Value |
| --- | --- |
| variable | `RELEASE_APP_CLIENT_ID` |
| variable | `RELEASE_APP_LOGIN=<app-slug>[bot]` |
| secret | `RELEASE_APP_PRIVATE_KEY` |
| App installation | selected access to `remote-client` |
| App permissions | Administration read, Contents read/write, Metadata read; the existing organization App may retain Pull requests/Issues read/write for Nexus release management |

Do not give the App Actions or Workflows permission. The publication token is
minted only in trusted default-branch code and scoped to this repository.
Candidate jobs never receive it.

## Review and recovery

- Default-branch changes require the protected PR checks and current-head
  review.
- Formal publication requires a second protected-environment approval.
- Publication is serialized by one repository-wide concurrency group and is
  never cancelled in progress.
- A failed run may resume only an App-authored compatible draft. Unexpected
  state remains for investigation instead of being silently deleted.
- Published tags and assets are immutable. Fixes require a new version.

The current non-secret certificate/key fingerprints and rotation status are in
the organization
[signing identity registry](https://github.com/camellia-computing/.github/blob/main/docs/SIGNING_IDENTITY_REGISTRY.md).
Private material is supplied only through the scoped secret groups documented
in [release signing modes](release-signing.md).

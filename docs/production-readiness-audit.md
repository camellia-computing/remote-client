# Camellia Remote production-readiness audit

Audit date: 2026-07-28
Scope: `remote-client`, `remote-protocol`, `remote-server`, and `remote-management-server`
Baseline policy: fresh repositories and current product/data identities only

## Decision

The source baseline is suitable for protected pre-release integration. No reviewed P0 source defect remains open. A production release is conditional on exact-commit hosted CI, every selected native package test, production secret/TLS configuration, signed artifact readback, and a timed recovery exercise.

## Architecture and authority review

| Boundary | Required invariant | Result |
| --- | --- | --- |
| Shared protocol | One independently versioned source is pinned by client and server; size/recursion/path limits fail closed | Pass |
| Client session | Authentication, peer identity, encryption, transport choice, input, clipboard, and file transfer remain bounded and auditable | Pass |
| Rendezvous/relay | Separate least-privilege processes, canonical ports, non-root OCI/native services, protected key material, and health checks | Pass |
| Management | PostgreSQL-only production state; SQLite is debug-only; encryption, device proof, proxy trust, uploads, OIDC, and audit have explicit bounds | Pass |
| Local data | New application IDs and directories are used; no obsolete development data migration or compatibility scanner is retained | Pass |
| Deployment | Immutable OCI digests, read-only containers, dropped capabilities, systemd hardening, explicit migration, and backup timer | Pass |
| Release | Stable SemVer, successful push CI reuse, protected approval, checksums, SBOM/provenance, attestations/signatures, and immutable assets | Pass with environment prerequisites |
| Legal | AGPL source/provenance obligations and upstream attribution are retained across every copied component | Pass |

## Findings resolved

### RM-P0-01 — Shared protocol could drift between independently copied repositories

Resolved by creating `remote-protocol`, pinning the same full submodule commit in client and server, preserving the public API, and running its 104-test suite from both consumers.

### RM-P0-02 — Product identity was mixed with upstream package, bundle, executable, and update identities

Resolved across Cargo/Flutter packages, FFI library loading, Windows executable metadata, Android/iOS/macOS/Linux identifiers, URI scheme, portable packer, artifacts, update allow-list, and management model names. Upstream references remain only where required for attribution, third-party forks, or protocol behavior.

### RM-P0-03 — Production management storage could silently use a local database

Resolved by requiring a credentialed PostgreSQL URL when `DEBUG=false`, moving the complete CI/deployment path to PostgreSQL 18, and allowing SQLite only in explicit local debug mode. The clean initial migration is exercised against PostgreSQL.

### RM-P1-01 — Old deployment assets mixed obsolete databases, names, and mutable images

Resolved with one hardened server Dockerfile/Compose model, role-specific systemd units, one PostgreSQL management stack, digest-pinned images, non-root users, read-only roots, dropped capabilities, health checks, and canonical names. Obsolete MySQL, Kubernetes, classic Docker, and development-database instructions were removed from the new baselines.

### RM-P1-02 — Recovery objectives were stated without executable backup ownership

Resolved by defining one-region 99.9%, RPO ≤ 1 hour, and RTO ≤ 4 hours; hourly atomic PostgreSQL backups for management; complete-state snapshots for identity/relay; encrypted off-site copies; quarterly restore drills; and digest-based rollback with forward database repair.

### RM-P1-03 — Windows scripts could select obsolete Windows PowerShell

Resolved by invoking only `pwsh` and the current PowerShell 7 installation path. No `powershell.exe` fallback remains.

## Verification evidence

- Shared protocol: the client and server pin commit `354c42c51174de3bad3097acdc8ee82247c7dbc0`; format, Clippy with warnings denied, and 104 unit tests passed.
- Identity/relay server: Rust check/format and protocol (104), identity (33), relay (21), utilities (2), and recursion (1) tests passed. The production image built successfully, runs as `10001:10001` with a read-only root, exposes canonical OCI labels, and returns successful help/version output before configuration startup.
- Client: the Linux workspace/all-target Flutter feature suite passed (87 client, 104 protocol, 4 portable-packer, 30 screen-capture, and 6 input tests, with one documented long-running codec matrix ignored by the ordinary gate). Flutter analysis reported no errors or warnings and all 66 widget/unit tests passed; inherited information-level lint and Rust warning debt remains explicitly non-blocking. Portable generation is deterministic and rejects unsafe inputs.
- Web client: protobuf codecs were regenerated from the pinned protocol, the TypeScript bridge lint/build and CSP/provenance synchronization check passed, and npm reported no vulnerabilities at the configured threshold.
- Management: Ruff format/check, Django migration drift, 48 ordinary tests (2 environment-specific skips), the real PostgreSQL test/deployment path, Compose expansion through Docker Desktop, release metadata, and systemd hardening analysis passed.
- All 22 repository workflow files passed Actionlint 1.7.12. Final management-image/Web provenance, every target-platform package, and platform-native acceptance remain mandatory hosted gates even where an equivalent local runner is unavailable.

## Residual risks and mandatory gates

1. Run the exact commits through required GitHub checks after the fresh roots are pushed. Cross-repository Web provenance cannot be accepted before the client commit exists on `main`.
2. Build and test every selected Windows/macOS/Linux/Android/iOS/Web artifact on its owning runner. Execute a Windows 11 installation, upgrade-free clean install, uninstall, multi-monitor, clipboard/file, privilege, sleep/wake, and network-transition acceptance pass.
3. Register release environments and trusted signing identities. Private/internal native signatures are acceptable for controlled distribution; public distribution should use recognized platform identities. Sigstore/attestation and checksum gates are mandatory in either mode.
4. Configure production TLS, origins, proxy overwrite rules, rate limits, PostgreSQL credentials, server keys, device-verification token, OIDC values, and monitoring without committing secrets.
5. Restore the latest identity state and PostgreSQL backup into an isolated environment, exercise registration, rendezvous, direct and relayed sessions, management login, and audit, and record measured RPO/RTO.
6. Confirm AGPL corresponding-source delivery for every distributed/network-deployed modified component and retain the exact source/protocol commits in release metadata.

Any failed gate is a release no-go. Exceptions require an owner, expiry, compensating control, and evidence; authorization, source-license, migration integrity, signature/attestation, and recovery gates are not waivable.

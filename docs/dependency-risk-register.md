# Rust dependency risk register

Review date: 2026-07-28
Owner: `camellia-computing/remote`

## Enforcement

The root `Cargo.lock` is the only reviewed Rust resolution for this workspace.
CI and the scheduled security workflow run the pinned `cargo-audit` release
through `.github/scripts/audit_cargo_dependencies.py`. The gate fails on:

- every vulnerability;
- every unregistered unmaintained, unsound, or yanked warning;
- malformed or duplicate exceptions;
- an expired exception group.

The machine-readable exception set is
`.github/config/cargo-audit-policy.json`. It is a warning budget, not an
advisory ignore list: `cargo-audit` still reports every item, and any new item
fails CI. Resolved entries may be removed at any time.

Workspace-member lock files are forbidden because Cargo ignores them when a
member is built from the root. The stale `libs/virtual_display/Cargo.lock`
created false assurance and ten Dependabot alerts, including a high-severity
`mio` advisory, even though released builds used the safe root resolution. It
has been removed and CI prevents a nested lock from returning.

The obsolete `quest` example dependency and its `rpassword 2.1.0` chain were
also removed. The example now uses standard input directly.

## Time-bounded exceptions

| Group | Scope | Expiry | Compensating control and exit |
| --- | --- | --- | --- |
| `gtk3-stack-migration` | GTK3 unmaintained notices and `glib 0.18` unsound iterator advisory | 2026-10-31 | No direct `VariantStrIter` use exists in product code; native Linux tests remain required. Exit by migrating the complete desktop integration to a maintained GTK/GLib stack. |
| `inherited-transitive-modernization` | Exact reviewed warnings inherited through upstream media, windowing, code-generation, and text stacks | 2026-10-31 | Exact package, version, category, and advisory identities are frozen; any growth fails. Remove entries as their owning upstream chains are upgraded or replaced. |
| `yanked-spin-transitive` | `spin 0.9.8` through `flume` in image/camera paths | 2026-08-31 | There is no RustSec vulnerability advisory, but the lock remains visible and time-bounded. Exit by upgrading the `flume`/image/nokhwa chains until the yanked release is absent. |

The GitHub alerts for the still-resolved `atty` and `glib` versions remain open
for visibility; they are not silently dismissed. A formal release after an
exception expiry is a no-go until the dependency is removed or a newly reviewed
exception with current evidence is approved.

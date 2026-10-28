# Remote printing delivery

Remote printing remains a required product capability. The missing capture
adapter and virtual-printer package are **not yet delivered**. This document is
an implementation contract, not an installation or end-to-end test certificate.

## Receiving a document

The owned `camellia-printing` crate submits MSXPS and OpenXPS through the Windows
Document Package API. There is no application-directory XPS DLL loader, shared
mutable function pointer, or runtime unloading. The existing receiving path
calls this boundary on its blocking print thread.

An explicit printer is never replaced with another destination. An omitted or
empty target resolves the current user's default once; query failure, buffer
growth, and malformed names fail. Printer names are limited to 1,024 UTF-16 units, with no
embedded NUL. Inputs are at most 64 MiB, 128 documents, and 4,096 total pages.
These limits are per submission, not a global queue or decompression budget.

The package and page object graphs are parsed before a system job is created;
lazy resource reads may still fail during writing and require cancellation.
Job/document/page print
tickets and rendering resources are preserved; absent optional resources are
distinct from parse errors. Unset advisory dimensions (`-1`) are valid. Restricted
font relationships must not be lost or silently made unrestricted. Source file
signatures are not attached to a new print rendition.

An incomplete submission is cancelled, including on Rust unwinding. A normal
failure preserves its original stage/HRESULT and a separate cancellation failure.
Diagnostics contain static stage codes and numeric errors, not document contents,
titles, printer names, or paths. No automatic retry occurs. Success only means
the package writer closed and the submission was accepted by the spooler; it is
not proof that physical pages printed.

## Remaining delivery work (BUILD-007)

1. Confirm the capture-side Windows support baseline. The modern PSA virtual
   printer API starts at Windows 11 24H2 (build 26100). Choosing that baseline for
   printing must not implicitly change the desktop-connection support range.
2. Deliver an owned virtual-printer background task and authenticated, bounded
   user-session broker. Remove the missing external Rust-ABI adapter rather than
   substitute an unlicensed/preinstalled binary. A modern queue must work with
   Windows Protected Print Mode, without a legacy port-monitor/driver dependency.
3. Bind each capture/transfer/receive job to explicit permission, connection
   generation, Windows user/session, and printer target. Supervise bounded jobs,
   bytes, workers, cancellation, timeout, and shutdown (AUTH-004 / RES-042).
   The existing detached receiving threads have **not** been fixed by the new
   submission boundary, nor is the compressed byte limit a decompression limit.
4. Build the complete x64/ARM64 capture payload from clean source. Cover exact
   hashes, architecture, publisher identity, license, provenance, and signing in
   zip/portable/MSI manifests. Development signing is not production signing and
   must not modify the operator host's trust roots.
5. Make install/upgrade/uninstall transactional, per-user registration observable,
   and rollback truthful (INSTALL-001). Do not report installed after staging
   alone, swallow selected-feature failures, or delete a working queue first.
6. In isolated Windows VMs, exercise real capture, transfer, print submission,
   offline/blocked spoolers, cancellation, multiple sessions, Protected Print
   Mode, package tampering, installation rollback, and uninstall cleanup. Local
   Linux tests and cross-target Clippy do not prove those native operations.

## Narrow checks

From the fixed Client checkout, under the workspace component lock:

```sh
cargo test --locked -p camellia-printing
cargo clippy --locked -p camellia-printing --all-targets -- -D warnings
cargo clippy --locked -p camellia-printing --all-targets --target x86_64-pc-windows-msvc -- -D warnings
cargo clippy --locked -p camellia-printing --all-targets --target aarch64-pc-windows-msvc -- -D warnings
```

The Windows test suite constructs tiny MSXPS/OpenXPS documents in memory and
checks COM/resource ownership; it deliberately creates no real system print job.

## Primary API contracts

- [Windows app support for OpenXPS](https://learn.microsoft.com/en-us/windows/win32/printdocs/app-support-for-openxps-printing)
- [OpenXPS-aware package reader](https://learn.microsoft.com/en-us/windows/win32/api/xpsobjectmodel_1/nf-xpsobjectmodel_1-ixpsomobjectfactory1-createpackagefromstream1)
- [Optional document print ticket](https://learn.microsoft.com/en-us/windows/win32/api/xpsobjectmodel/nf-xpsobjectmodel-ixpsomdocument-getprintticketresource)
- [Advisory dimensions](https://learn.microsoft.com/en-us/windows/win32/api/xpsobjectmodel/nf-xpsobjectmodel-ixpsompagereference-setadvisorypagedimensions)
- [Document and restricted-font relationships](https://learn.microsoft.com/en-us/windows/win32/api/xpsobjectmodel/nf-xpsobjectmodel-ixpsompackagewriter-startnewdocument)
- [PSA virtual printer manifest](https://learn.microsoft.com/en-us/windows-hardware/drivers/devapps/msix-manifest-specification-print-support-virtual-printer)
- [Windows Protected Print Mode](https://learn.microsoft.com/en-us/windows/modern-print/windows-protected-print-mode/windows-protected-print-mode)

# Scoped Windows portable-service bootstrap

This is an owned AGPL-3.0-only component, not code imported from the retired
`impersonate_system` dependency. It serves the existing, already-elevated
interactive startup path. It does not bypass UAC, authorize remote callers,
launch arbitrary programs or declare the portable service ready.

The launcher fixes the image to this same executable, holds it against writes
and deletion, and builds only the documented portable-service arguments. A
bounded shared-memory identifier and original executable-name metadata are the
only caller-supplied values. No password, token, arbitrary command, parent PATH
or ambient process environment is forwarded.

An existing thread impersonation context is rejected without changing it.
Otherwise a private copy of the elevated process token temporarily enables
only the required privileges on this thread. The parent process token is not
edited. A source token must prove LocalSystem identity and the caller's session
while its process/token handles remain open; a process name or PID is not the
authority. The new primary token is rechecked before use.

The child starts suspended with a fresh, non-inherited token environment and a
system-directory working directory. Its token, session and file identity are
checked before the calling thread's original context is restored and the child
is resumed. Uncommitted children are terminated on errors, and all handles have
owned cleanup. A failure to restore temporary thread privileges is fatal: the
application must not continue in that context. Errors contain only a fixed
stage and numeric Win32 code, never paths, command lines or environment values.

The generic state-machine tests prove validation, failure cleanup order and
repeatability; MSVC-target Clippy proves neither real token privileges nor a
successful SYSTEM launch. Native Windows tests and controlled portable-service
startup, filesystem, multi-session and failure verification are still required.
In particular, file-identity support is filesystem-specific; do not silently
drop identity checks or infer removable-media coverage from an NTFS CI runner.

From the Client root:

```bash
cargo test --locked -p camellia-windows-bootstrap
cargo clippy --locked -p camellia-windows-bootstrap --all-targets -- -D warnings
cargo clippy --locked -p camellia-windows-bootstrap --all-targets \
  --target x86_64-pc-windows-msvc -- -D warnings
```

Primary Win32 contracts used for this independent implementation:

- [DuplicateTokenEx](https://learn.microsoft.com/windows/win32/api/securitybaseapi/nf-securitybaseapi-duplicatetokenex)
- [AdjustTokenPrivileges](https://learn.microsoft.com/windows/win32/api/securitybaseapi/nf-securitybaseapi-adjusttokenprivileges)
- [CreateProcessWithTokenW](https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-createprocesswithtokenw)
- [CreateEnvironmentBlock](https://learn.microsoft.com/windows/win32/api/userenv/nf-userenv-createenvironmentblock)
- [FILE_ID_INFO](https://learn.microsoft.com/windows/win32/api/winbase/ns-winbase-file_id_info)
- [GetFileInformationByHandle](https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-getfileinformationbyhandle)

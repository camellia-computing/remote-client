# Management CLI outcome contract

The control commands are `camellia-remote-admin users`, `devices`, `device-groups`
and `strategies`. They require the current Management operation-receipt and
mutation-generation contracts. Unsupported invitation/2FA/email-verification
commands are not advertised or retained as speculative API clients.

## Locked installation

The Client owns this Python package, its root `pyproject.toml` and `uv.lock`.
Use CPython 3.13–3.15 and exactly uv 0.13.5:

```sh
uv sync --locked
uv run --locked camellia-remote-admin --help
uv run --locked camellia-remote-admin users --help
```

The single entry point also exposes `address-books`, `audits` and `operations`.
The former `res/*.py` entry paths are removed, not kept as forwarding scripts;
`user-groups` has no Management provider and is not a command.
The runtime uses Requests and its locked dependencies, not Management's virtual
environment. Global help can be read without importing HTTP dependencies; a
missing dependency produces installation guidance, not a traceback.

Packaging is still in development: independent CI, offline hash-verified
artifact installation and release evidence remain rollout gates. Address-book
reader/provider alignment is tracked separately as `COMPAT-011`; installation
alone is not a claim that every API operation has completed acceptance testing.

Each mutation freezes its target/version snapshot before the first write and
prints its digest. Multiple targets require confirmation unless `--yes` is
specified. Every individual operation has its own UUIDv4. One explicit
`--operation-id` may identify one atomic batch, but cannot identify several
independent per-target requests.

| Exit | Meaning |
| --- | --- |
| 0 | Exact completion receipts, or explicitly permitted empty selection |
| 1 | Unknown outcome, transport loss, malformed/mismatched receipt |
| 2 | Invalid command, selector, input or local precondition |
| 3 | No matching targets / missing named resource |
| 4 | Partial completion; inspect confirmed, unknown and unattempted operations |
| 5 | Remote rejection or inventory HTTP failure |
| 130 | User cancellation / interruption before any confirmed partial completion |

`--allow-empty` permits a valid selection that matches zero resources to finish
without any mutation request. It never permits malformed comma lists, duplicate
targets, a missing explicitly named resource, or an invalid assignment. Query
commands may return an empty list without this flag.

Use `--json` for automation. Stdout then contains one JSON document; prompts and
progress go to stderr. Mutation reports contain the target digest, requested and
confirmed applied counts, operation IDs/states, result digests and `not_attempted`
targets. They omit request bodies, passwords and bearer tokens. A failed later
request never erases earlier confirmed receipts or claims that an unknown
operation was rolled back. No automatic compensation is attempted.

## Exact target selection

User/device inventory filters are exact by default. Where Management permits
them, explicitly supplied `prefix%` or `%substring%` filters remain available;
the CLI does not silently add wildcards. Device IDs accept only the server's
exact mode.

Strategy assignment selectors are unambiguous:

- `--peers 840005002` or `--peers id:840005002`: public device RID.
- `--peers guid:7`: Management device database identifier, not RID `7`.
- `--users alice` / `name:alice`: exact username, including all-numeric names.
- `--users guid:7`: Management user database identifier.
- `--device-groups group-name` / `name:group-name`: exact group name.
- `--device-groups guid:<uuid>`: Management device-group UUID.

All resolved targets and generations are frozen before strategy assignment.
Aliases resolving to the same resource are rejected rather than applied twice.

## Unknown outcomes

Do not blindly rerun or reverse a partially completed command. Recover each
`unknown` operation through `camellia-remote-admin operations --operation-id <uuid>` with the
same Management actor. This reads the immutable receipt without replaying a
mutation. Retention expiry or a missing receipt is not proof that no mutation
occurred. `not_attempted` entries are the only requests the CLI knows it did not
send. Mutation retries require the complete original request/generation snapshot.

## HTTP budget and cancellation

All admin HTTP calls use the package's `transport` module. The command's monotonic budget
defaults to 60 seconds (`--deadline`); each connect/TLS wait defaults to 5 seconds
(`--connect-timeout`) and read-idle wait to 10 (`--read-timeout`). Values must be
finite and between 0.05 and 600 seconds. Parsing, startup, confirmations, all
pages and all targets consume one budget; a nested command cannot extend it.
Cancellation/timeout adds bounded cleanup grace (normally below one second).

A spawned, disposable worker owns the Requests Session and every socket. This
also bounds blocked DNS and a continuously trickling body, which Requests' idle
timeouts alone cannot bound. The same command reuses its Session/connection;
the parent stops and joins the worker on deadline, Ctrl-C or SIGTERM. Programmatic
multi-request callers must use `with camellia_remote_admin.transport.command_transport():` to share
the operation budget; individual unscoped requests remain bounded and close.

There are no automatic retries, including GET/429/503, and redirects are not
followed. Inspect Retry-After/status before running a fresh read. Mutation loss
remains `unknown`, not rolled back; requests rejected locally before dispatch
remain `not_attempted`. The last confirmed receipts and remaining targets stay
in the batch report. Only the original actor's receipt can resolve an unknown ID.

TLS verification cannot be disabled; HTTPS is required except for loopback HTTP
development. Ambient proxy/netrc configuration is deliberately not inherited,
and a command cannot switch origins. JSON requests are capped at 1MiB and
decompressed JSON responses at 4MiB. HTML, redirects and oversized responses
produce typed failures without printing raw bodies/URLs/exceptions. Payloads,
tokens and passwords travel over private IPC, never a temporary request file.

Do not manually install arbitrary dependencies into the locked environment.

## Focused tests

```sh
uv run --locked python -m unittest discover -s tools/admin-cli/tests -q
```

The optional `tools/admin-cli/tests/test_management_cli_contract.py` runs the real Django routes,
authorization, receipts and database mutations, not HTTP stubs. In the exact
Management checkout with its locked test dependencies, run:

```sh
CAMELLIA_REMOTE_DEBUG=true CAMELLIA_REMOTE_SECRET_KEY=local-test-only \
CAMELLIA_REMOTE_MANAGEMENT_CONTRACT_TESTS=1 \
PYTHONPATH=<client-checkout>/tools/admin-cli/src:<client-checkout>/tools/admin-cli/tests \
python -m pytest -c pyproject.toml -q <client-checkout>/tools/admin-cli/tests/test_management_cli_contract.py
```

Use only an isolated development/test database. PostgreSQL-specific concurrency,
multi-worker behavior and real Win11 execution remain separate verification
requirements; SQLite contract success does not prove those boundaries.

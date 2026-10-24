# Management CLI outcome contract

The supported control tools are `res/users.py`, `devices.py`, `device-groups.py`
and `strategies.py`. They require the current Management operation-receipt and
mutation-generation contracts. Unsupported invitation/2FA/email-verification
commands are not advertised or retained as speculative API clients.

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
`unknown` operation through `res/operations.py --operation-id <uuid>` with the
same Management actor. This reads the immutable receipt without replaying a
mutation. Retention expiry or a missing receipt is not proof that no mutation
occurred. `not_attempted` entries are the only requests the CLI knows it did not
send. Mutation retries require the complete original request/generation snapshot.

HTTP deadlines and standalone locked CLI packaging are separate rollout gates;
this outcome contract does not claim that an unresponsive network is bounded or
that arbitrary system Python environments already contain the required runtime.

## Focused tests

```sh
PYTHONPATH=res python -m unittest -q res/test_batch_operations.py res/test_admin_cli.py
```

The optional `res/test_management_cli_contract.py` runs the real Django routes,
authorization, receipts and database mutations, not HTTP stubs. In the exact
Management checkout with its locked test dependencies, run:

```sh
CAMELLIA_REMOTE_DEBUG=true CAMELLIA_REMOTE_SECRET_KEY=local-test-only \
CAMELLIA_REMOTE_MANAGEMENT_CONTRACT_TESTS=1 PYTHONPATH=<client-checkout>/res \
python -m pytest -c pyproject.toml -q <client-checkout>/res/test_management_cli_contract.py
```

Use only an isolated development/test database. PostgreSQL-specific concurrency,
multi-worker behavior and real Win11 execution remain separate verification
requirements; SQLite contract success does not prove those boundaries.

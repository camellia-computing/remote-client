# Native address book mutation protocol (implementation in progress)

`flutter/lib/models/address_book_mutations.dart` is the pure-Dart protocol core
for the seven Management peer/tag write routes. Storage adapters and read-only
receipt recovery are implemented. GUI/transport lifecycle integration is
**not implemented yet**; STATE-044 remains open. The
in-memory journal in the unit tests is a test seam, not a persistence fallback.

Each command freezes its UUIDv4, method, path, exact UTF-8 JSON body, observed
`If-Match` and canonical request digest before awaiting anything. HTTPS is
required except for explicit loopback development. Redirects and retries are not
part of this service contract; the transport adapter must not add them.

A batch validates/freezes its whole selection first (1–1000 child requests,
at most 4 MiB of frozen bodies). Every successful child advances exactly one
generation. All children share one monotonic 30-second budget (maximum 10
minutes when explicitly configured). A conflict, unknown result or journal
cleanup failure stops the batch and retains confirmed receipts, unknown original
IDs and the number not attempted. It never retries a rejected or unknown child
using a new ID or a newly fetched generation. A received receipt must not relabel
stale visible content: the UI must reconcile a fresh complete content snapshot.

Before sending, the adapter must durably and atomically reserve the operation.
Any unresolved record, including another actor/endpoint's record, blocks new
mutations. Persist **only** operation ID, display timestamp and opaque scope;
never passwords, tokens, bodies, paths or request digests. Scope derives from the
normalized Management endpoint and the authenticated actor's own personal-book
GUID, not their username or bearer token. Wall-clock time never proves whether
an operation committed and cannot expire an unknown reservation.

Malformed/HTML/oversized/5xx/timeout/lost responses remain unknown. Only strict
immutable receipts release reservations. Failed cleanup preserves the confirmed
outcome but keeps admission blocked. Recovery must use GET for the original ID
and original actor/endpoint; 404 or retention expiry is not proof of no commit.
Recovery never reconstructs or replays a write. It takes the original
ID/scope/time, checks the original actor's immutable receipt and only then
acknowledges that same record. Lookup does not require a local record still to
exist: another window may have acknowledged it already. A different local
reservation is never removed. The returned generation is historical evidence,
not an editable cache version. A failed recovery stays unknown; it is not
reported as proof that the original mutation was never sent.

## Storage boundary

Native uses `src/management_operation_journal.rs` through one generated bridge
method. A process mutex and nonblocking OS file lock serialize all engines and
processes. The journal is under the application's private config directory in
`management-operation-journal-v1` (Unix 0700/0600). An operation's UUID is also its
filename, so a failed/partial write does not erase its identity. Reservations use
exclusive file creation, file sync and Unix directory sync; only an exact
ID/scope/time acknowledgement removes a record. Other records, malformed files,
symlinks and unexpected entries are never automatically repaired or evicted.
Native Windows/macOS crash durability still needs owning-platform validation.

The browser adapter uses same-origin Web Locks with fail-fast exclusive admission
and canonical, checksummed localStorage metadata. Storage/quota/lock failure
prevents send. Both adapters intentionally allow only one unresolved operation
at a time, including another actor/endpoint's record; this is a fail-closed
availability tradeoff, not a queue that discards older operations. Corruption
requires preserving the original IDs and operator reconciliation, not a reset
based on 404, age or a changed clock. The native lock is not implemented with
[Dart's process-level POSIX advisory locks](https://api.dart.dev/dart-io/RandomAccessFile/lock.html).

The seven-vector `flutter/test/fixtures/address_book_mutations_v1.json` corpus is
also checked by Management's canonical-document implementation. Dart VM tests
cover the protocol/state machine. To check Dart's compiled-JavaScript arithmetic,
UTF-8 and digests without running a fullscreen GUI:

```bash
# From flutter/, using the repository's locked Dart/Flutter SDK.
dart compile js -O2 test/support/address_book_mutations_js_probe.dart -o /private/cache/mutations.js
node ../.github/scripts/test-address-book-mutations-js.cjs /private/cache/mutations.js
```

That Node probe is not a real-browser/Web Locks, network, platform or GUI test.
The analogous `address_book_journal_web_probe.dart` and
`test-address-book-journal-web.cjs` run the compiled browser adapter against
DOM/storage/lock substitutes for deterministic competition and fault injection.
The production transport still requires the RES-001 cancellation/request-identity
boundary; timing out a Future alone does not reclaim its underlying worker.

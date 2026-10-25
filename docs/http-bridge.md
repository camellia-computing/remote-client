# HTTP bridge ownership (implementation in progress)

All native Flutter HTTP requests use one versioned bridge protocol. The generated
Dart bridge and native engine must be rebuilt together. There is no URL-keyed or
unbounded Flutter-HTTP alternative. The bridge runs on the existing FRB Tokio
runtime; it does not create an OS thread or runtime for each request.

| Boundary | Limit / ownership |
| --- | --- |
| Active request futures | 8; cancellation keeps the permit until the future drops |
| Unconsumed outcomes | 32 entries, at most 8 MiB serialized data |
| Request / decoded response body | 1 MiB each |
| Accepted headers | 64 fields / 16 KiB; HTTP parser limits still apply before validation |
| Native request budget | 12 seconds including response streaming |
| Completed result lifetime | 30 seconds, consumed exactly once; periodic expiry also cancels stale workers |
| Reusable HTTP client | One origin and explicit proxy configuration; at most 8 old handles in active workers |
| System DNS for HTTP/proxies | 8 admitted OS lookups shared by clients; at most 64 returned addresses |

Native assigns a canonical UUIDv4 using fallible OS entropy. Poll and cancel use
that exact identity, never the URL. Completed and failed outcomes consume their
own entry. An unknown/missing request cannot select another caller's response.
The Dart caller cancels a late admission even after its own deadline. Responses
carry bounded headers and base64-encoded original bytes, not charset-normalized
text. Transport errors contain allowlisted codes only, not URLs, bodies or proxy
credentials. A transport failure does not prove a mutation failed to commit.

Native selects HTTP or the explicitly configured rendezvous raw-TCP route once
before sending. An explicit HTTP/HTTPS/SOCKS proxy takes precedence over raw TCP;
bad proxy configuration cannot create a direct client. Redirects and transparent
reqwest retries are disabled. The bridge never switches transport after an
uncertain result. Other native telemetry POST callers still have a separate
historical fallback path; this is not a claim that NET-004's entire scope is done.
That POST path now captures its explicit proxy and full-origin routing policy
before awaiting transport. A failed explicit proxy cannot become raw TCP because
live settings changed later. Its no-proxy fallback behavior is separate from the
bridge's single-attempt contract.

Recording upload clients are lazy and bound to their last successfully built
proxy policy. Each request checks the current policy, removes a stale client
before constructing its replacement, and fails closed on invalid configuration.
The worker keeps its durable upload state and receiver so repairing configuration
can resume it without replaying a recording as a new upload. Sync/async factories
share one Rustls verifier policy; proxy TLS errors never create direct clients.

Web uses `AbortableRequest` with redirects disabled, a bounded response stream,
deadline and explicit client close. Cancellation does not cancel a parent batch
token after a successful child. Address-book reset/book switching cancels its
owned mutation/read; receipt ownership and durable unknown records remain
independent of transport cleanup. Whole-batch deadlines cancel transport as well
as rejecting late UI publication.

Protocol TLS selection is stateless (`TlsType::for_url`): HTTP/WS is plaintext,
HTTPS/WSS uses Rustls, invalid schemes fail closed. Successful hosts are not
retained in a global discovery cache.

System DNS uses a shared fail-fast admission limit. The blocking OS closure owns
its permit until it really returns, including when its async waiter is cancelled.
There is no age-based eviction, fallback resolver or unbounded DNS admission
queue. If all OS calls stall, further lookups fail closed until those calls return.
HTTP deadlines still return promptly; they do not claim to kill getaddrinfo.

Remaining gates: Protocol raw-TCP/TCP/UDP resolver paths are still RES-003's scope;
cover owning-platform engine/Web behavior, raw-TCP integration and resource
measurements. No passing
unit suite proves these gates. The current pre-maintenance lock graph also fails
the dependency audit; accepted maintenance source/SDK/locks/provenance must be
integrated together. Do not widen audit exceptions or describe this feature
branch as deployable.

The compiled `http_browser_probe.dart` exercises the actual package:http
BrowserClient with Node fetch/AbortController/ReadableStream substitutes, including
header/body abort and oversized-reader cancellation. It runs in the existing
contract script; it is not a real browser, network, CORS or TLS acceptance test.

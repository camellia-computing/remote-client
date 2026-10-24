"""Bounded CLI HTTP. A disposable worker owns every socket and its Session.

Requests' read timeout is an idle timeout, not a total/DNS deadline. Keeping the
network in a spawned process lets the parent stop it even during DNS/TLS or a
slow response. No payload is written to disk and mutations are never retried.
"""

import argparse
import contextvars
import ipaddress
import json
import math
import multiprocessing
import pickle
import signal
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from urllib.parse import urlsplit

import requests

MAX_REQUEST_BYTES = 1024 * 1024
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
_ACTIVE = contextvars.ContextVar("remote_cli_transport", default=None)
_METHODS = frozenset({"GET", "POST", "PUT", "PATCH", "DELETE"})


@contextmanager
def _cleanup_signals():
    previous = {}
    if threading.current_thread() is threading.main_thread():
        for kind in (signal.SIGINT, signal.SIGTERM):
            previous[kind] = signal.signal(kind, signal.SIG_IGN)
    try:
        yield
    finally:
        for kind, handler in previous.items():
            signal.signal(kind, handler)


@contextmanager
def _defer_start_cancellation():
    # Process.start must finish publishing ownership before cancellation unwinds.
    previous = {}
    interrupted = False

    def defer(_signum, _frame):
        nonlocal interrupted
        interrupted = True

    if threading.current_thread() is threading.main_thread():
        for kind in (signal.SIGINT, signal.SIGTERM):
            previous[kind] = signal.signal(kind, defer)
    try:
        yield
    finally:
        for kind, handler in previous.items():
            signal.signal(kind, handler)
    if interrupted:
        raise KeyboardInterrupt


class TransportFailure(requests.RequestException):
    def __init__(self, kind, *, sent=False, status=0):
        # Never include an exception, URL, credentials, request or response body.
        super().__init__(f"Management transport {kind}")
        self.kind = kind
        self.sent = sent
        self.status = status


def _seconds(value):
    try:
        number = float(value)
    except (ValueError, TypeError):
        raise argparse.ArgumentTypeError("Timeout must be a finite number") from None
    if not math.isfinite(number) or not 0.05 <= number <= 600:
        raise argparse.ArgumentTypeError("Timeout must be between 0.05 and 600 seconds")
    return number


def add_options(parser):
    parser.add_argument(
        "--deadline",
        type=_seconds,
        default=60.0,
        help="Total command budget, including all pages/targets (default: 60 seconds)",
    )
    parser.add_argument(
        "--connect-timeout",
        type=_seconds,
        default=5.0,
        help="Per-connect/TLS idle timeout (default: 5 seconds)",
    )
    parser.add_argument(
        "--read-timeout",
        type=_seconds,
        default=10.0,
        help="Per-read idle timeout, still limited by --deadline (default: 10 seconds)",
    )


@dataclass(frozen=True)
class Response:
    status_code: int
    headers: dict
    content: bytes

    @property
    def text(self):
        # Used by existing diagnostic consumers; it is always a bounded JSON body.
        return self.content.decode("utf-8", errors="replace")

    def json(self):
        try:
            return json.loads(self.content.decode("utf-8"))
        except (UnicodeError, RecursionError, ValueError):
            raise TransportFailure(
                "invalid_json", sent=True, status=self.status_code
            ) from None


def _worker(connection):
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        with requests.Session() as session:
            session.trust_env = False  # No ambient proxy/netrc can receive a bearer.
            adapter = requests.adapters.HTTPAdapter(
                pool_connections=1, pool_maxsize=1, max_retries=0
            )
            session.mount("http://", adapter)
            session.mount("https://", adapter)
            while True:
                item = connection.recv()
                if item is None:
                    return
                method, url, options, connect_timeout, read_timeout = item
                try:
                    session.cookies.clear()
                    with session.request(
                        method,
                        url,
                        **options,
                        stream=True,
                        allow_redirects=False,
                        timeout=(connect_timeout, read_timeout),
                        verify=True,
                    ) as response:
                        status = response.status_code
                        headers = {
                            key: response.headers[key][:128]
                            for key in ("Content-Type", "X-Request-ID", "Retry-After")
                            if key in response.headers
                        }
                        length = response.headers.get("Content-Length")
                        if length is not None and (
                            not length.isascii()
                            or not length.isdigit()
                            or int(length) > MAX_RESPONSE_BYTES
                        ):
                            connection.send(("error", "response_limit", status))
                            continue
                        media_type = (
                            response.headers.get("Content-Type", "")
                            .split(";", 1)[0]
                            .strip()
                            .lower()
                        )
                        if media_type != "application/json":
                            connection.send(("error", "response_type", status))
                            continue
                        body = bytearray()
                        for chunk in response.iter_content(chunk_size=4096):
                            if len(body) + len(chunk) > MAX_RESPONSE_BYTES:
                                break
                            body.extend(chunk)
                        else:
                            connection.send(("response", status, headers, bytes(body)))
                            continue
                        connection.send(("error", "response_limit", status))
                except requests.Timeout:
                    connection.send(("error", "idle_timeout", 0))
                except requests.RequestException:
                    connection.send(("error", "connection", 0))
                except (ValueError, OverflowError):
                    connection.send(("error", "protocol", 0))
    except (EOFError, BrokenPipeError, OSError, KeyboardInterrupt):
        pass  # Parent owns cancellation and emits the only CLI diagnostic.
    finally:
        connection.close()


class Transport:
    def __init__(self, *, deadline=60.0, connect_timeout=5.0, read_timeout=10.0):
        self.deadline = time.monotonic() + _seconds(deadline)
        self._started_at = time.monotonic()
        self._configured = False
        self.connect_timeout = _seconds(connect_timeout)
        self.read_timeout = _seconds(read_timeout)
        self._process = None
        self._connection = None
        self._rpc_thread = None
        self._busy = threading.Lock()
        self._closed = False
        self._origin = None

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TransportFailure("deadline")
        return remaining

    def _start(self):
        if self._process is None:
            context = multiprocessing.get_context("spawn")
            parent, child = context.Pipe()
            process = context.Process(
                target=_worker, args=(child,), daemon=True, name="remote-cli-http"
            )
            self._connection, self._process = parent, process
            try:
                with _defer_start_cancellation():
                    try:
                        process.start()
                    finally:
                        child.close()
            except (OSError, RuntimeError):
                self.close()
                raise TransportFailure("worker_start") from None

    def close(self):
        if self._closed:
            return
        self._closed = True
        with _cleanup_signals():
            self._stop_worker()

    def _stop_worker(self):
        process = self._process
        if process is not None and process.pid is not None:
            if process.is_alive() and (
                self._rpc_thread is None or not self._rpc_thread.is_alive()
            ):
                try:
                    self._connection.send(None)
                except (EOFError, BrokenPipeError, OSError):
                    pass
                process.join(timeout=0.1)
            if process.is_alive():
                # Terminate the socket owner, not just the waiting client thread.
                process.terminate()
                process.join(timeout=0.25)
            if process.is_alive():
                process.kill()
                process.join(timeout=0.25)
            if not process.is_alive():
                process.join(timeout=0)
                process.close()
        elif process is not None:
            process.close()
        if self._connection is not None:
            self._connection.close()
        if self._rpc_thread is not None:
            self._rpc_thread.join(timeout=0.25)

    def request(self, method, url, **options):
        if not self._busy.acquire(blocking=False):
            raise TransportFailure("concurrent_request")
        sent = False
        try:
            if self._closed:
                raise TransportFailure("closed")
            remaining = self.remaining()
            try:
                parsed = urlsplit(url)
                origin = (
                    parsed.scheme,
                    parsed.hostname,
                    parsed.port or (443 if parsed.scheme == "https" else 80),
                )
                loopback = parsed.hostname == "localhost"
                if not loopback:
                    try:
                        loopback = ipaddress.ip_address(
                            parsed.hostname or ""
                        ).is_loopback
                    except ValueError:
                        pass
                if (
                    method not in _METHODS
                    or parsed.scheme not in {"http", "https"}
                    or not parsed.hostname
                    or parsed.username is not None
                    or parsed.password is not None
                    or parsed.fragment
                    or (parsed.scheme == "http" and not loopback)
                    or (self._origin is not None and origin != self._origin)
                    or set(options) - {"headers", "params", "json"}
                ):
                    raise ValueError
                headers = dict(options.get("headers", {}))
                headers["Accept"] = "application/json"
                for header in headers.items():
                    requests.utils.check_header_validity(header)
                if any(
                    ord(character) <= 32 or ord(character) == 127 for character in url
                ):
                    raise ValueError
                options = {**options, "headers": headers}
                encoded = json.dumps(options, allow_nan=False).encode("utf-8")
                if len(encoded) > MAX_REQUEST_BYTES or len(url) > 8192:
                    raise ValueError
            except (
                TypeError,
                ValueError,
                OverflowError,
                requests.exceptions.InvalidHeader,
            ):
                raise TransportFailure("invalid_request") from None
            self._origin = origin
            self._start()
            remaining = self.remaining()
            result = []
            done = threading.Event()

            def rpc():
                try:
                    self._connection.send(
                        (
                            method,
                            url,
                            options,
                            min(self.connect_timeout, remaining),
                            min(self.read_timeout, remaining),
                        )
                    )
                    result.append(self._connection.recv())
                except (EOFError, OSError, ValueError, TypeError, pickle.PickleError):
                    # Only the private IPC boundary is opaque; no raw exception/body escapes.
                    result.append(("error", "worker_lost", 0))
                finally:
                    done.set()

            self._rpc_thread = threading.Thread(
                target=rpc, daemon=True, name="remote-cli-http-rpc"
            )
            # Once the worker can receive the request its commit outcome is unknown.
            sent = True
            self._rpc_thread.start()
            if not done.wait(timeout=self.remaining()):
                raise TransportFailure("deadline", sent=True)
            self._rpc_thread.join()
            self.remaining()
            reply = result[0]
            if reply[0] == "error":
                raise TransportFailure(reply[1], sent=True, status=reply[2])
            return Response(reply[1], reply[2], reply[3])
        except TransportFailure as error:
            error.sent = error.sent or sent
            self.close()
            raise
        except KeyboardInterrupt as error:
            error.request_sent = sent
            self.close()
            raise
        finally:
            self._busy.release()


@contextmanager
def command_transport():
    existing = _ACTIVE.get()
    if existing is not None:
        yield existing
        return
    with Transport() as instance:
        token = _ACTIVE.set(instance)
        main_thread = threading.current_thread() is threading.main_thread()
        previous_sigterm = None
        if main_thread:

            def cancelled(_signum, _frame):
                raise KeyboardInterrupt

            previous_sigterm = signal.signal(signal.SIGTERM, cancelled)
        try:
            yield instance
        finally:
            try:
                instance.close()
            finally:
                if main_thread:
                    signal.signal(signal.SIGTERM, previous_sigterm)
                _ACTIVE.reset(token)


def configure(args):
    instance = _ACTIVE.get()
    if instance is None:
        return  # Programmatic callers use an explicit command_transport scope.
    if instance._process is not None:
        raise TransportFailure("already_started")
    # First parsing sets the command's configured budget; nested entry cannot extend it.
    requested_deadline = instance._started_at + _seconds(args.deadline)
    instance.deadline = (
        min(instance.deadline, requested_deadline)
        if instance._configured
        else requested_deadline
    )
    instance._configured = True
    instance.connect_timeout = _seconds(args.connect_timeout)
    instance.read_timeout = _seconds(args.read_timeout)


def request(method, url, **options):
    with command_transport() as instance:
        return instance.request(method, url, **options)


def get(url, **options):
    return request("GET", url, **options)


def post(url, **options):
    return request("POST", url, **options)


def put(url, **options):
    return request("PUT", url, **options)


def patch(url, **options):
    return request("PATCH", url, **options)


def delete(url, **options):
    return request("DELETE", url, **options)

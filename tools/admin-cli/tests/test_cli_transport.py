import argparse
import contextlib
import io
import json
import multiprocessing
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from camellia_remote_admin import transport
from camellia_remote_admin.outcomes import CliError, ExitCode, Mutation, run_mutations


def stalled_dns_worker(connection):
    def stall(*_args, **_kwargs):
        time.sleep(60)

    socket.getaddrinfo = stall
    transport._worker(connection)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            pass  # Terminating the worker deliberately resets keep-alive sockets.

    def do_GET(self):
        self.server.seen.append(
            (self.path, self.client_address[1], self.headers.get("Accept"))
        )
        try:
            if self.path.startswith("/slow-headers"):
                time.sleep(2)
            if self.path.startswith("/redirect"):
                self.send_response(302)
                self.send_header("Location", "https://must-not-follow.invalid/")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = b'{"data":[],"total":0,"response_schema_version":1}'
            self.send_response(
                429
                if self.path.startswith("/rate")
                else 503
                if self.path.startswith("/unavailable")
                else 200
            )
            self.send_header(
                "Content-Type",
                "text/html" if self.path.startswith("/html") else "application/json",
            )
            self.send_header(
                "Content-Length",
                str(transport.MAX_RESPONSE_BYTES + 1)
                if self.path.startswith("/oversize")
                else str(len(body)),
            )
            self.send_header("Retry-After", "30")
            self.end_headers()
            if self.path.startswith("/slow-body"):
                for byte in body:
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                    time.sleep(0.1)
            elif self.path.startswith("/truncated"):
                self.wfile.write(body[:5])
                self.close_connection = True
            else:
                self.wfile.write(body)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


class TransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.server.daemon_threads = True
        cls.server.seen = []
        cls.thread = threading.Thread(
            target=lambda: cls.server.serve_forever(poll_interval=0.05), daemon=True
        )
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def setUp(self):
        self.children_before = {
            child.pid for child in multiprocessing.active_children()
        }

    def tearDown(self):
        self.assertEqual(
            {child.pid for child in multiprocessing.active_children()},
            self.children_before,
        )
        self.assertFalse(
            any(
                thread.name == "remote-cli-http-rpc" for thread in threading.enumerate()
            )
        )

    def test_session_reuses_one_socket_and_never_retries_429_or_503(self):
        start = len(self.server.seen)
        with transport.Transport(deadline=5) as client:
            first = client.request("GET", self.url + "/normal")
            self.assertEqual(first.json()["total"], 0)
            for path, status in (("/rate", 429), ("/unavailable", 503)):
                response = client.request("GET", self.url + path)
                self.assertEqual(response.status_code, status)
                self.assertEqual(response.headers["Retry-After"], "30")
        seen = self.server.seen[start:]
        self.assertEqual(len(seen), 3)
        self.assertEqual(len({row[1] for row in seen}), 1)
        self.assertTrue(all(row[2] == "application/json" for row in seen))

    def test_total_deadline_covers_dns_headers_and_trickling_body(self):
        for stage in ("dns", "slow-headers", "slow-body"):
            with self.subTest(stage=stage):
                started = time.monotonic()
                with contextlib.ExitStack() as stack:
                    if stage == "dns":
                        stack.enter_context(
                            patch(
                                "camellia_remote_admin.transport._worker",
                                stalled_dns_worker,
                            )
                        )
                    client = stack.enter_context(
                        transport.Transport(deadline=0.8, read_timeout=5)
                    )
                    with self.assertRaises(transport.TransportFailure) as failed:
                        client.request("GET", self.url + "/" + stage)
                    self.assertEqual(failed.exception.kind, "deadline")
                    self.assertTrue(failed.exception.sent)
                self.assertLess(time.monotonic() - started, 1.8)

    def test_html_redirect_oversize_and_mid_body_disconnect_are_bounded(self):
        for path, kind in (
            ("/html", "response_type"),
            ("/redirect", "response_type"),
            ("/oversize", "response_limit"),
            ("/truncated", "connection"),
        ):
            with self.subTest(path=path), transport.Transport(deadline=4) as client:
                with self.assertRaises(transport.TransportFailure) as failed:
                    client.request("GET", self.url + path)
                self.assertEqual(failed.exception.kind, kind)
                self.assertNotIn("must-not-follow", str(failed.exception))

    def test_expired_budget_is_not_sent_and_mutation_summary_retains_remaining_target(
        self,
    ):
        with transport.Transport(deadline=0.05) as client:
            client.deadline = time.monotonic() - 1
            with self.assertRaises(transport.TransportFailure) as failed:
                client.request("POST", self.url, json={"password": "private-canary"})
            self.assertFalse(failed.exception.sent)
        mutation = Mutation(
            {"users": ["1"]}, lambda _key: client.request("POST", self.url)
        )
        with (
            contextlib.redirect_stdout(io.StringIO()),
            self.assertRaises(CliError) as failed,
        ):
            run_mutations("users", [mutation], yes=True)
        self.assertEqual(
            failed.exception.summary["operations"][0]["state"], "not_attempted"
        )
        self.assertEqual(failed.exception.summary["not_attempted"], [{"users": ["1"]}])
        self.assertEqual(failed.exception.code, ExitCode.REMOTE_ERROR)

    def test_one_deadline_is_shared_by_pages_and_nested_configuration_cannot_extend_it(
        self,
    ):
        parser = argparse.ArgumentParser()
        transport.add_options(parser)
        with transport.command_transport() as client:
            transport.configure(parser.parse_args(["--deadline", "0.8"]))
            deadline = client.deadline
            with transport.command_transport() as nested:
                self.assertIs(client, nested)
                transport.configure(parser.parse_args(["--deadline", "600"]))
                self.assertEqual(client.deadline, deadline)
            transport.get(self.url + "/normal")
            with self.assertRaises(transport.TransportFailure) as failed:
                transport.get(self.url + "/slow-body")
            self.assertEqual(failed.exception.kind, "deadline")

    def test_invalid_settings_or_urls_never_start_a_worker_or_expose_credentials(self):
        for value in ("nan", "inf", "0", "601"):
            with self.assertRaises(argparse.ArgumentTypeError):
                transport.Transport(deadline=value)
        for url, options in (
            ("http://remote.example.test", {}),
            ("https://private-canary@example.test", {}),
            (self.url, {"verify": False}),
            (self.url, {"headers": {"Authorization": "private-canary\n"}}),
        ):
            with (
                transport.Transport() as client,
                self.assertRaises(transport.TransportFailure) as failed,
            ):
                client.request("GET", url, **options)
            self.assertFalse(failed.exception.sent)
            self.assertIsNone(client._process)
            self.assertNotIn("canary", str(failed.exception))

    def test_script_mocks_never_mutate_the_process_shared_transport(self):
        from test_batch_operations import load_script

        original_get = transport.get
        script = load_script("devices.py", "isolated_transport_script")
        script.transport.get = lambda *_args, **_kwargs: None
        self.assertIs(transport.get, original_get)

    def test_malformed_utf8_and_json_are_typed_without_raw_body(self):
        for body in (b"\xff", b"{private-canary", b"[" * 2000):
            with self.assertRaises(transport.TransportFailure) as failed:
                transport.Response(200, {}, body).json()
            self.assertEqual(failed.exception.kind, "invalid_json")
            self.assertNotIn("canary", str(failed.exception))

    def test_cli_deadline_has_nonzero_safe_json_exit_without_traceback(self):
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "camellia_remote_admin",
                "devices",
                "view",
                "--url",
                self.url + "/slow-headers",
                "--token",
                "private-canary",
                "--json",
                "--deadline",
                "0.8",
            ],
            capture_output=True,
            text=True,
            timeout=4,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        envelope = json.loads(result.stdout)
        self.assertEqual(envelope["reason"], "deadline")
        self.assertNotIn("canary", result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_connection_refusal_and_header_idle_timeout_are_classified(self):
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            port = reserved.getsockname()[1]
        for url, read_timeout, expected in (
            (f"http://127.0.0.1:{port}", 5, "connection"),
            (self.url + "/slow-headers", 0.1, "idle_timeout"),
        ):
            with transport.Transport(deadline=3, read_timeout=read_timeout) as client:
                with self.assertRaises(transport.TransportFailure) as failed:
                    client.request("GET", url)
                self.assertEqual(failed.exception.kind, expected)

    def test_tls_handshake_stall_obeys_parent_deadline(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(2)
            stop = threading.Event()

            def hold_handshake():
                try:
                    connection, _ = listener.accept()
                    with connection:
                        stop.wait(2)
                except OSError:
                    pass

            thread = threading.Thread(target=hold_handshake, daemon=True)
            thread.start()
            try:
                with transport.Transport(deadline=0.8) as client:
                    with self.assertRaises(transport.TransportFailure) as failed:
                        client.request(
                            "GET", f"https://127.0.0.1:{listener.getsockname()[1]}"
                        )
                    self.assertEqual(failed.exception.kind, "deadline")
            finally:
                stop.set()
                thread.join(timeout=2.5)
            self.assertFalse(thread.is_alive())

    def test_eight_concurrent_failures_reclaim_workers_threads_and_file_descriptors(
        self,
    ):
        fd_path = Path("/proc/self/fd")
        before = len(list(fd_path.iterdir())) if fd_path.is_dir() else None

        def fail_once(_index):
            started = time.monotonic()
            with transport.Transport(deadline=1.5, read_timeout=5) as client:
                with self.assertRaises(transport.TransportFailure) as failed:
                    client.request("GET", self.url + "/slow-headers")
                self.assertEqual(failed.exception.kind, "deadline")
            return time.monotonic() - started

        with ThreadPoolExecutor(max_workers=8) as pool:
            durations = list(pool.map(fail_once, range(8)))
        self.assertLess(max(durations), 3)
        if before is not None:
            # Fixture sockets live in this process too; let the fake server's
            # deliberate 2s header delay observe the already-closed clients.
            drain_deadline = time.monotonic() + 2
            while (
                len(list(fd_path.iterdir())) > before + 1
                and time.monotonic() < drain_deadline
            ):
                time.sleep(0.01)
            self.assertLessEqual(len(list(fd_path.iterdir())), before + 1)

    def test_cancellation_during_worker_start_still_has_an_owned_cleanable_child(self):
        process_type = multiprocessing.get_context("spawn").Process
        original_start = process_type.start

        def start_then_cancel(process):
            original_start(process)
            signal.raise_signal(signal.SIGINT)

        with (
            patch.object(process_type, "start", start_then_cancel),
            transport.Transport() as client,
        ):
            with self.assertRaises(KeyboardInterrupt) as cancelled:
                client.request("GET", self.url)
            self.assertFalse(cancelled.exception.request_sent)

    @unittest.skipUnless(os.name == "posix", "POSIX process-group signal contract")
    def test_sigint_group_and_sigterm_release_socket_worker_and_exit_nonzero(self):
        for cancellation in (signal.SIGINT, signal.SIGTERM):
            start = len(self.server.seen)
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "camellia_remote_admin",
                    "devices",
                    "view",
                    "--url",
                    self.url + "/slow-headers",
                    "--token",
                    "private-canary",
                    "--json",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 3
                while len(self.server.seen) == start and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertGreater(len(self.server.seen), start)
                os.killpg(process.pid, cancellation)
                stdout, stderr = process.communicate(timeout=3)
                self.assertNotEqual(process.returncode, 0)
                self.assertNotIn("canary", stdout + stderr)
                self.assertNotIn("Traceback", stderr)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=3)


if __name__ == "__main__":
    unittest.main()

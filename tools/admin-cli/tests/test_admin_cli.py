import io
import json
import signal
import socket
import subprocess
import sys
import threading
import unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
from urllib.parse import urlsplit

from camellia_remote_admin.outcomes import (
    CliError,
    ExitCode,
    Mutation,
    control_mutations,
    run_mutations,
    split_targets,
)
from test_batch_operations import FakeResponse, control_receipt, load_script


class OutcomeTests(unittest.TestCase):
    def test_malformed_inventory_timestamp_is_typed_not_a_traceback(self):
        module = load_script("devices.py", "timestamp_devices")
        for timestamp in (None, "not-a-time", "2026-10-24T10:00:00"):
            response = FakeResponse({"data": [{"last_online": timestamp}], "total": 1})
            with (
                patch.object(module.transport, "get", return_value=response),
                self.assertRaises(CliError) as failed,
            ):
                module.view("https://management.example.test", "test", offline_days=1)
            self.assertEqual(failed.exception.code, ExitCode.UNKNOWN)

    def test_numeric_device_ids_and_names_are_not_guessed_as_database_guids(self):
        module = load_script("strategies.py", "selector_strategies")
        rows = [
            {"guid": "1", "id": "7", "name": "7"},
            {"guid": "7", "id": "840005002", "name": "other"},
        ]
        captured = []

        def get(url, *, headers, params):
            captured.append(params)
            field = next(key for key in ("guid", "id", "name") if key in params)
            matches = [row for row in rows if row[field] == params[field]]
            return FakeResponse({"data": matches, "total": len(matches)})

        with patch.object(module.transport, "get", side_effect=get):
            self.assertEqual(
                module.get_device_target("https://example.test", "test", "7")["guid"],
                "1",
            )
            self.assertEqual(
                module.get_device_target("https://example.test", "test", "guid:7")[
                    "guid"
                ],
                "7",
            )
            self.assertEqual(
                module.get_user_target("https://example.test", "test", "7")["guid"], "1"
            )
        self.assertEqual(
            captured,
            [
                {"pageSize": 2, "id": "7"},
                {"pageSize": 2, "guid": "7"},
                {"pageSize": 2, "name": "7"},
            ],
        )

    def test_exact_filters_are_not_silently_expanded_into_wildcards(self):
        for filename, options, expected in (
            ("users.py", {"name": "alice"}, {"name": "alice"}),
            ("devices.py", {"id": "840005002"}, {"id": "840005002"}),
            (
                "device_groups.py",
                {"id": "840005002", "group_name": "group"},
                {"id": "840005002", "device_group_name": "group"},
            ),
        ):
            module = load_script(filename, "filter_" + filename.replace("-", "_"))
            captured = {}

            def get(url, *, headers, params, captured=captured):
                captured.update(params)
                return FakeResponse({"data": [], "total": 0})

            with patch.object(module.transport, "get", side_effect=get):
                method = (
                    module.view_devices
                    if filename == "device_groups.py"
                    else module.view
                )
                method("https://management.example.test", "test-only", **options)
            for key, value in expected.items():
                self.assertEqual(captured[key], value)

    def test_duplicate_operation_ids_fail_before_any_write(self):
        key = "11111111-1111-4111-8111-111111111111"
        mutations = [
            Mutation(
                {"users": [identifier]}, lambda key: self.fail("must not mutate"), key
            )
            for identifier in ("7", "8")
        ]
        with self.assertRaises(CliError) as failed:
            run_mutations("disable", mutations, yes=True)
        self.assertEqual(failed.exception.code, ExitCode.INVALID)
        for invalid in (None, 1, "not-a-uuid"):
            with (
                self.subTest(operation_id=invalid),
                self.assertRaises(CliError) as failed,
            ):
                run_mutations(
                    "disable",
                    [
                        Mutation(
                            {"users": ["7"]},
                            lambda key: self.fail("must not mutate"),
                            invalid,
                        )
                    ],
                )
            self.assertEqual(failed.exception.code, ExitCode.INVALID)

    def test_cancel_and_empty_are_explicit_not_silent_success(self):
        for allowed in (False, True):
            with self.subTest(allowed=allowed):
                if allowed:
                    self.assertEqual(
                        run_mutations("disable", [], allow_empty=True)["applied"], {}
                    )
                else:
                    with self.assertRaises(CliError) as failed:
                        run_mutations("disable", [])
                    self.assertEqual(failed.exception.code, ExitCode.NO_MATCH)
        mutation = Mutation(
            {"users": ["7", "8"]}, lambda key: self.fail("must not mutate")
        )
        with (
            patch("builtins.input", return_value="N"),
            redirect_stdout(io.StringIO()),
            self.assertRaises(CliError) as failed,
        ):
            run_mutations("disable", [mutation])
        self.assertEqual(failed.exception.code, ExitCode.CANCELLED)
        self.assertEqual(failed.exception.summary["operations"], [])

    def test_all_generations_are_preflighted_before_any_callback(self):
        rows = [
            {"guid": "7", "mutation_generation": 0},
            {"guid": "8", "mutation_generation": None},
        ]
        with self.assertRaises(CliError) as failed:
            control_mutations(
                rows, "users", lambda row, key: self.fail("must not mutate")
            )
        self.assertEqual(failed.exception.code, ExitCode.INVALID)

    def test_split_never_silently_discards_invalid_or_duplicate_targets(self):
        for value in ("", ", ,", "one,", "one,one"):
            with self.subTest(value=value), self.assertRaises(CliError) as failed:
                split_targets(value, "targets")
            self.assertEqual(failed.exception.code, ExitCode.INVALID)


class SubprocessOutcomeTests(unittest.TestCase):
    def setUp(self):
        self.rows = [
            {
                "guid": str(n),
                "name": f"user-{n}",
                "id": f"device-{n}",
                "mutation_generation": 0,
            }
            for n in (7, 8, 9)
        ]
        self.mutations = []
        self.mode = "success"
        self.list_status = 200
        self.received = threading.Event()
        self.release = threading.Event()
        case = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def respond(self, status, body):
                encoded = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def do_GET(self):
                if case.mode == "html-list":
                    self.send_response(200)
                    self.send_header("Content-Length", "13")
                    self.end_headers()
                    self.wfile.write(b"<html></html>")
                    return
                self.respond(
                    case.list_status, {"data": case.rows, "total": len(case.rows)}
                )

            def mutate(self):
                parts = urlsplit(self.path).path.split("/")
                resource, guid = parts[2], parts[3]
                operation = ("user" if resource == "users" else "device") + (
                    "_delete" if self.command == "DELETE" else "_status_" + parts[4]
                )
                document = {
                    "operation": operation,
                    "user" if resource == "users" else "device": guid,
                    "expected_generation": int(self.headers["If-Match"].strip('"')),
                }
                wire_key = self.headers["Idempotency-Key"]
                if not wire_key.startswith("v2:"):
                    self.respond(400, {"code": "invalid_operation_key"})
                    return
                key = wire_key[3:]
                body = control_receipt(
                    operation, document, {resource: 1}, operation_id=key
                )
                case.mutations.append((guid, key))
                case.received.set()
                if case.mode == "interrupt":
                    case.release.wait(5)
                    return
                if case.mode == "lost-second" and len(case.mutations) == 2:
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                status = 200
                if case.mode == "partial":
                    body["applied"] = {resource: 0}
                if case.mode == "stale":
                    status = 409
                    body.pop("result")
                    body.update(
                        code="stale_generation",
                        message="Stale inventory",
                        retryable=False,
                        applied={resource: 0},
                    )
                self.respond(status, body)

            do_POST = mutate
            do_DELETE = mutate

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(
            target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True
        )
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.addCleanup(self.cleanup_server)

    def cleanup_server(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def argv(self, script, command, *args):
        return [
            sys.executable,
            "-m",
            "camellia_remote_admin",
            script.removesuffix(".py").replace("_", "-"),
            command,
            "--url",
            self.url,
            "--token",
            "cli-test-secret-not-for-logs",
            "--json",
            *args,
        ]

    def cli(self, script, command, *args, stdin=""):
        result = subprocess.run(
            self.argv(script, command, *args),
            input=stdin,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
        body = json.loads(result.stdout)
        self.assertNotIn("cli-test-secret-not-for-logs", result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        return result, body

    def test_zero_match_requires_allow_empty_for_both_control_scripts(self):
        self.rows = []
        for script in ("users.py", "devices.py"):
            for command in ("enable", "disable", "delete"):
                with self.subTest(script=script, command=command):
                    result, body = self.cli(script, command)
                    self.assertEqual(result.returncode, ExitCode.NO_MATCH)
                    self.assertEqual(body["operations"], [])
                    result, body = self.cli(script, command, "--allow-empty")
                    self.assertEqual(result.returncode, 0)
                    self.assertEqual(body["result"], "success")
        self.assertEqual(self.mutations, [])

    def test_one_and_many_targets_confirm_exact_counts_and_operation_ids(self):
        for script, resource in (("users.py", "users"), ("devices.py", "devices")):
            for count in (1, 3):
                with self.subTest(script=script, count=count):
                    self.rows = (
                        self.rows[:count]
                        if count == 1
                        else [
                            {
                                "guid": str(n),
                                "name": f"user-{n}",
                                "id": f"device-{n}",
                                "mutation_generation": 0,
                            }
                            for n in (7, 8, 9)
                        ]
                    )
                    result, body = self.cli(script, "disable", "--yes")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(body["requested"], {resource: count})
                    self.assertEqual(body["applied"], {resource: count})
                    self.assertEqual(body["not_attempted"], [])
                    self.assertEqual(
                        len({o["operation_id"] for o in body["operations"]}), count
                    )
                    self.assertTrue(
                        all(o["state"] == "applied" for o in body["operations"])
                    )

    def test_cancel_or_eof_is_nonzero_and_sends_no_mutations(self):
        for stdin in ("N\n", ""):
            result, body = self.cli("users.py", "disable", stdin=stdin)
            self.assertEqual(result.returncode, ExitCode.CANCELLED)
            self.assertEqual(body["result"], "cancelled")
        self.assertEqual(self.mutations, [])

    def test_invalid_assign_and_separator_only_lists_fail_before_network(self):
        for script, command, args in (
            ("devices.py", "assign", []),
            ("devices.py", "assign", ["--assign_to", "note"]),
            ("devices.py", "assign", ["--assign_to", "invalid=value"]),
            ("device_groups.py", "delete", ["--name", ", ,"]),
            ("device_groups.py", "add-devices", ["--name", "g", "--ids", ",,"]),
            ("strategies.py", "assign", ["--name", "p", "--peers", "x,"]),
            ("users.py", "invite", []),
        ):
            with self.subTest(script=script, command=command, args=args):
                result, _ = self.cli(script, command, *args)
                self.assertEqual(result.returncode, ExitCode.INVALID)
        self.assertEqual(self.mutations, [])

    def test_empty_group_and_strategy_batches_only_succeed_with_allow_empty(self):
        for script, command in (
            ("device_groups.py", "delete"),
            ("device_groups.py", "add-devices"),
            ("device_groups.py", "remove-devices"),
            ("strategies.py", "unassign"),
        ):
            with self.subTest(script=script, command=command):
                result, _ = self.cli(script, command)
                self.assertEqual(result.returncode, ExitCode.NO_MATCH)
                result, body = self.cli(script, command, "--allow-empty")
                self.assertEqual(result.returncode, 0)
                self.assertEqual(body["operations"], [])
        self.assertEqual(self.mutations, [])

    def test_http_and_malformed_inventory_errors_are_not_success(self):
        for status in (401, 403, 409, 500):
            self.list_status = status
            result, _ = self.cli("users.py", "disable")
            self.assertEqual(result.returncode, ExitCode.REMOTE_ERROR)
        self.list_status = 200
        self.mode = "html-list"
        result, _ = self.cli("users.py", "disable")
        self.assertEqual(result.returncode, ExitCode.UNKNOWN)
        self.assertEqual(self.mutations, [])

    def test_lost_second_response_retains_confirmed_unknown_and_unattempted(self):
        self.mode = "lost-second"
        result, body = self.cli("users.py", "disable", "--yes")
        self.assertEqual(result.returncode, ExitCode.PARTIAL)
        self.assertEqual(body["applied"], {"users": 1})
        self.assertEqual(
            [o["state"] for o in body["operations"]], ["applied", "unknown"]
        )
        self.assertEqual(body["not_attempted"], [{"users": ["9"]}])
        self.assertEqual(len(self.mutations), 2)

    def test_durable_rejection_and_partial_receipt_have_nonzero_typed_results(self):
        self.rows = self.rows[:1]
        for mode, code in (
            ("stale", ExitCode.REMOTE_ERROR),
            ("partial", ExitCode.PARTIAL),
        ):
            self.mode = mode
            result, body = self.cli("devices.py", "disable")
            self.assertEqual(result.returncode, code)
            self.assertEqual(body["applied"], {"devices": 0})
            self.assertEqual(body["operations"][0]["state"], "rejected")

    def test_ctrl_c_reports_unknown_operation_and_exits_without_traceback(self):
        self.rows = self.rows[:1]
        self.mode = "interrupt"
        process = subprocess.Popen(
            self.argv("users.py", "disable"),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            self.assertTrue(self.received.wait(3))
            process.send_signal(signal.SIGINT)
            stdout, stderr = process.communicate(timeout=3)
            self.assertEqual(process.returncode, ExitCode.CANCELLED)
            self.assertEqual(json.loads(stdout)["operations"][0]["state"], "unknown")
            self.assertNotIn("Traceback", stderr)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()

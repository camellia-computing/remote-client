import importlib.util
import io
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

RES_DIR = Path(__file__).resolve().parent
UNSUPPORTED_COMMANDS = (
    "invite",
    "enable-2fa-enforce",
    "disable-2fa-enforce",
    "disable-email-verification",
    "reset-2fa",
)


def load_users_script():
    spec = importlib.util.spec_from_file_location(
        "compat_009_users", RES_DIR / "users.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Compat009Tests(unittest.TestCase):
    def test_help_exposes_only_management_routes_that_exist(self):
        users = load_users_script()
        output = io.StringIO()
        argv = ["users.py", "--help"]

        with (
            patch.object(sys, "argv", argv),
            redirect_stdout(output),
            self.assertRaises(SystemExit) as raised,
        ):
            users.main()

        self.assertEqual(raised.exception.code, 0)
        help_text = output.getvalue()
        self.assertIn("view", help_text)
        self.assertIn("force-logout", help_text)
        for command in UNSUPPORTED_COMMANDS:
            self.assertNotIn(command, help_text)
        self.assertFalse(hasattr(users, "invite_user"))
        self.assertFalse(hasattr(users, "enable_2fa_enforce"))
        self.assertFalse(hasattr(users, "disable_2fa_enforce"))
        self.assertFalse(hasattr(users, "disable_email_verification"))
        self.assertFalse(hasattr(users, "reset_2fa"))

    def test_removed_commands_fail_during_argument_parsing_without_http(self):
        users = load_users_script()

        def unexpected_http(*_args, **_kwargs):
            self.fail("unsupported command must not issue an HTTP request")

        users.requests = SimpleNamespace(get=unexpected_http, post=unexpected_http)
        for command in UNSUPPORTED_COMMANDS:
            with self.subTest(command=command):
                argv = [
                    "users.py",
                    command,
                    "--url",
                    "https://management.example.test",
                    "--token",
                    "token",
                ]
                errors = io.StringIO()
                with (
                    patch.object(sys, "argv", argv),
                    redirect_stderr(errors),
                    self.assertRaises(SystemExit) as raised,
                ):
                    users.main()
                self.assertEqual(raised.exception.code, 2)
                self.assertIn("invalid choice", errors.getvalue())


if __name__ == "__main__":
    unittest.main()

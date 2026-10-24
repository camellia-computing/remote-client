"""Opt-in contract tests against the exact checked-out Management application.

Run from Management using its locked pytest/Django environment; never connects
to a production database or installs Client dependencies into Management.
"""

import io
import json
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from json import dumps
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import urlsplit

import requests

if os.environ.get("CAMELLIA_REMOTE_MANAGEMENT_CONTRACT_TESTS") != "1":
    raise unittest.SkipTest("requires explicit Management contract-test environment")

from admin_cli import entry
from api.models import (
    DeviceGroup,
    ManagementBatchOperation,
    RemoteDevice,
    StrategyProfile,
    UserProfile,
)
from api.views_api import _issue_access_token
from batch_operations import recover_operation
from django.test import TestCase, override_settings
from test_batch_operations import load_script


@override_settings(
    STORAGES={
        "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
        "staticfiles": {
            "BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"
        },
    }
)
class ManagementCliContractTests(TestCase):
    def setUp(self):
        self.admin = UserProfile.objects.create_superuser(
            "cli-admin", "isolated-cli-admin-password"
        )
        self.auth_device = self.device("cli-auth", "840005001")
        self.target = self.device("cli-target", "840005002")
        _, self.bearer = _issue_access_token(self.admin, self.auth_device)
        self.requests = SimpleNamespace(
            **{
                method: self.transport(method)
                for method in ("get", "post", "patch", "put", "delete")
            }
        )
        self.calls = []

    def device(self, hostname, rid):
        return RemoteDevice.objects.create(
            rid=rid,
            uuid=hostname,
            owner=self.admin,
            hostname=hostname,
            username=self.admin.username,
            is_active=True,
            cpu="-",
            memory="-",
            os="Linux",
            version="test",
        )

    def transport(self, method):
        def request(url, *, headers, params=None, json=None):
            path = urlsplit(url).path
            self.calls.append((method, path))
            extra = {
                "HTTP_" + key.upper().replace("-", "_"): value
                for key, value in headers.items()
                if key.lower() != "content-type"
            }
            if method == "get":
                response = self.client.get(path, data=params or {}, **extra)
            else:
                response = getattr(self.client, method)(
                    path, data=dumps(json), content_type="application/json", **extra
                )
            return SimpleNamespace(
                status_code=response.status_code,
                json=response.json,
                text=response.content.decode(),
            )

        return request

    def invoke(self, filename, command, *args, expected_exit=0):
        module = load_script(filename, "cli_contract_" + filename.replace("-", "_"))
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            patch.object(module, "requests", self.requests),
            patch.object(
                sys,
                "argv",
                [
                    filename,
                    command,
                    "--url",
                    "https://management.example.test",
                    "--token",
                    self.bearer,
                    "--json",
                    "--yes",
                    *args,
                ],
            ),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            code = 0
            try:
                entry(module.main)
            except SystemExit as exc:
                code = exc.code
            self.assertEqual(code, expected_exit, stdout.getvalue() + stderr.getvalue())
        self.assertNotIn(self.bearer, stdout.getvalue() + stderr.getvalue())
        result = json.loads(stdout.getvalue())
        self.assertEqual(
            result["result"], "success" if expected_exit == 0 else "failed", result
        )
        if expected_exit == 0:
            self.assertEqual(result["requested"], result["applied"])
        for operation in result.get("operations", []):
            receipt = ManagementBatchOperation.objects.get(
                operation_id=operation["operation_id"]
            )
            if operation["state"] == "applied":
                self.assertEqual(
                    receipt.response["result_digest"], operation["result_digest"]
                )
        return result

    def test_user_lifecycle_and_force_logout_match_real_receipts(self):
        self.invoke(
            "users.py",
            "new",
            "--name",
            "cli-created",
            "--password",
            "unrelated-strong-creation-password",
        )
        user = UserProfile.objects.get(username="cli-created")
        for command, active in (("disable", False), ("enable", True)):
            self.invoke("users.py", command, "--name", user.username)
            user.refresh_from_db()
            self.assertEqual(user.is_active, active)
        self.invoke("users.py", "force-logout", "--name", user.username)
        self.invoke("users.py", "delete", "--name", user.username)
        self.assertFalse(UserProfile.objects.filter(pk=user.pk).exists())

    def test_device_status_assignment_and_delete_match_real_receipts(self):
        for command, active in (("disable", False), ("enable", True)):
            self.invoke("devices.py", command, "--id", self.target.rid)
            self.target.refresh_from_db()
            self.assertEqual(self.target.is_active, active)
        self.invoke(
            "devices.py",
            "assign",
            "--id",
            self.target.rid,
            "--assign_to",
            "note=verified-cli-note",
        )
        self.target.refresh_from_db()
        self.assertEqual(self.target.note, "verified-cli-note")
        self.invoke("devices.py", "delete", "--id", self.target.rid)
        self.assertFalse(RemoteDevice.objects.filter(pk=self.target.pk).exists())

    def test_group_lifecycle_and_membership_match_real_receipts(self):
        self.invoke("device-groups.py", "add", "--name", "cli-group")
        self.invoke(
            "device-groups.py", "update", "--name", "cli-group", "--note", "new-note"
        )
        self.assertEqual(DeviceGroup.objects.get(name="cli-group").note, "new-note")
        self.invoke(
            "device-groups.py",
            "add-devices",
            "--name",
            "cli-group",
            "--ids",
            self.target.rid,
        )
        self.target.refresh_from_db()
        self.assertEqual(self.target.device_group.name, "cli-group")
        self.invoke(
            "device-groups.py",
            "remove-devices",
            "--name",
            "cli-group",
            "--ids",
            self.target.rid,
        )
        self.target.refresh_from_db()
        self.assertIsNone(self.target.device_group_id)
        self.invoke("device-groups.py", "delete", "--name", "cli-group")
        self.assertFalse(DeviceGroup.objects.filter(name="cli-group").exists())

    def test_all_group_deletions_are_preflighted_and_multi_target_counts_match(self):
        for name in ("cli-one", "cli-two", "cli-three"):
            DeviceGroup.objects.create(name=name)
        self.invoke(
            "device-groups.py",
            "delete",
            "--name",
            "cli-one,cli-missing",
            expected_exit=3,
        )
        self.assertFalse(any(method == "delete" for method, _ in self.calls))
        self.assertTrue(DeviceGroup.objects.filter(name="cli-one").exists())
        result = self.invoke(
            "device-groups.py", "delete", "--name", "cli-one,cli-two,cli-three"
        )
        self.assertEqual(result["applied"], {"groups": 3})
        self.assertEqual(len(result["operations"]), 3)
        self.assertFalse(DeviceGroup.objects.filter(name__startswith="cli-").exists())

    def test_response_lost_after_real_commit_is_unknown_until_receipt_recovery(self):
        post = self.requests.post

        def lose_response(*args, **kwargs):
            response = post(*args, **kwargs)
            self.assertEqual(response.status_code, 200)
            raise requests.ConnectionError("simulated response loss")

        self.requests.post = lose_response
        result = self.invoke(
            "devices.py", "disable", "--id", self.target.rid, expected_exit=1
        )
        self.target.refresh_from_db()
        self.assertFalse(self.target.is_active)
        self.assertEqual(result["operations"][0]["state"], "unknown")
        with patch("batch_operations.requests.get", side_effect=self.requests.get):
            recovered = recover_operation(
                "https://management.example.test",
                self.bearer,
                result["operations"][0]["operation_id"],
            )
        self.assertEqual(recovered["receipt"]["applied"], {"devices": 1})
        self.assertEqual(sum(method == "post" for method, _ in self.calls), 1)

    def test_strategy_lifecycle_and_cross_resource_assignment_match_real_receipts(self):
        user = UserProfile.objects.create_user("cli-member", "isolated-member-password")
        group = DeviceGroup.objects.create(name="cli-policy-group")
        self.invoke("strategies.py", "add", "--name", "cli-policy")
        self.invoke(
            "strategies.py",
            "update",
            "--name",
            "cli-policy",
            "--new-name",
            "cli-policy-renamed",
        )
        for command, enabled in (("disable", False), ("enable", True)):
            self.invoke("strategies.py", command, "--name", "cli-policy-renamed")
            self.assertEqual(
                StrategyProfile.objects.get(name="cli-policy-renamed").enabled, enabled
            )
        targets = (
            "--peers",
            self.target.rid,
            "--users",
            user.username,
            "--device-groups",
            group.name,
        )
        self.invoke("strategies.py", "assign", "--name", "cli-policy-renamed", *targets)
        for obj in (self.target, user, group):
            obj.refresh_from_db()
            self.assertEqual(obj.strategy.name, "cli-policy-renamed")
        self.invoke("strategies.py", "unassign", *targets)
        for obj in (self.target, user, group):
            obj.refresh_from_db()
            self.assertIsNone(obj.strategy_id)
        self.invoke("strategies.py", "delete", "--name", "cli-policy-renamed")
        self.assertFalse(
            StrategyProfile.objects.filter(name="cli-policy-renamed").exists()
        )

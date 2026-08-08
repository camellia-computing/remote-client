import importlib.util
import io
import sys
import unittest
import uuid
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from batch_operations import (
    check_batch_response,
    check_control_response,
    document_digest,
)

RES_DIR = Path(__file__).resolve().parent
OPERATION_ID = "11111111-1111-4111-8111-111111111111"


class FakeResponse:
    def __init__(self, body, status_code=200):
        self._body = body
        self.status_code = status_code
        self.text = str(body)

    def json(self):
        return self._body


def receipt(operation, request_document, requested, *, operation_id=OPERATION_ID):
    return {
        "result": "OK",
        "management_operation_receipt_version": 1,
        "operation_id": operation_id,
        "operation": operation,
        "operation_generation": 7,
        "request_digest": document_digest(request_document),
        "result_digest": "a" * 64,
        "requested": requested,
        "applied": requested,
    }


def control_receipt(
    operation,
    request_document,
    requested,
    *,
    operation_id=OPERATION_ID,
    applied=None,
    error=None,
):
    body = receipt(
        operation,
        request_document,
        requested,
        operation_id=operation_id,
    )
    body["applied"] = requested if applied is None else applied
    if error is not None:
        body.pop("result", None)
        body["error"] = error
    return body


def load_script(filename, module_name):
    spec = importlib.util.spec_from_file_location(module_name, RES_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BatchOperationReceiptTests(unittest.TestCase):
    def test_cross_repository_canonical_request_digest_vector(self):
        self.assertEqual(
            document_digest(
                {
                    "operation": "strategy_assign",
                    "strategy": None,
                    "peers": ["3"],
                    "users": ["7"],
                    "groups": [],
                }
            ),
            "b3d8410e88bab3094afb36a53805c627ac7464110657382d2865700c1ed1a8d3",
        )

    def test_exact_receipt_is_accepted(self):
        request_document = {
            "operation": "users_force_logout",
            "users": ["7", "9"],
        }
        expected = {"users": 2}
        body = receipt("users_force_logout", request_document, expected)

        accepted = check_batch_response(
            FakeResponse(body),
            operation="users_force_logout",
            operation_id=OPERATION_ID,
            request_document=request_document,
            requested=expected,
        )

        self.assertEqual(accepted, body)

    def test_partial_or_mismatched_receipt_is_a_nonzero_failure(self):
        request_document = {
            "operation": "strategy_assign",
            "strategy": None,
            "peers": ["3"],
            "users": ["7"],
            "groups": [],
        }
        expected = {"devices": 1, "users": 1, "groups": 0}
        body = receipt("strategy_assign", request_document, expected)
        body["applied"] = {"devices": 1, "users": 0, "groups": 0}

        with self.assertRaisesRegex(SystemExit, "1"):
            check_batch_response(
                FakeResponse(body),
                operation="strategy_assign",
                operation_id=OPERATION_ID,
                request_document=request_document,
                requested=expected,
            )

        body = receipt("strategy_assign", request_document, expected)
        body["requested"] = {"devices": True, "users": 1, "groups": 0}
        body["applied"] = {"devices": True, "users": 1, "groups": 0}
        with self.assertRaisesRegex(SystemExit, "1"):
            check_batch_response(
                FakeResponse(body),
                operation="strategy_assign",
                operation_id=OPERATION_ID,
                request_document=request_document,
                requested=expected,
            )

    def test_user_force_logout_binds_header_digest_and_exact_count(self):
        users = load_script("users.py", "batch_users_script")
        request_document = {
            "operation": "users_force_logout",
            "users": ["7", "9"],
        }
        captured = {}

        def post(url, *, headers, json):
            captured.update(url=url, headers=headers, json=json)
            return FakeResponse(
                receipt("users_force_logout", request_document, {"users": 2})
            )

        users.requests.post = post
        result = users.force_logout(
            "https://management.example.test",
            "token",
            ["7", "9"],
            operation_id=OPERATION_ID,
        )

        self.assertEqual(result["applied"], {"users": 2})
        self.assertEqual(captured["headers"]["Idempotency-Key"], OPERATION_ID)
        self.assertEqual(captured["json"], {"user_guids": ["7", "9"]})

    def test_zero_user_force_logout_exits_nonzero(self):
        users = load_script("users.py", "batch_zero_users_script")
        users.view = lambda *_args: []
        argv = [
            "users.py",
            "force-logout",
            "--url",
            "https://management.example.test",
            "--token",
            "token",
            "--name",
            "missing",
        ]

        with patch.object(sys, "argv", argv), self.assertRaisesRegex(SystemExit, "1"):
            users.main()

    def test_strategy_assignment_validates_the_cross_type_receipt(self):
        strategies = load_script("strategies.py", "batch_strategies_script")
        strategy_guid = "33333333-3333-4333-8333-333333333333"
        group_guid = "44444444-4444-4444-8444-444444444444"
        request_document = {
            "operation": "strategy_assign",
            "strategy": strategy_guid,
            "peers": ["3"],
            "users": ["7"],
            "groups": [group_guid],
        }
        expected = {"devices": 1, "users": 1, "groups": 1}
        captured = {}
        strategies.get_strategy_by_name = lambda *_args: {"guid": strategy_guid}

        def post(url, *, headers, json):
            captured.update(url=url, headers=headers, json=json)
            return FakeResponse(receipt("strategy_assign", request_document, expected))

        strategies.requests.post = post
        result = strategies.assign_strategy(
            "https://management.example.test",
            "token",
            "locked-down",
            peers=["3"],
            users=["7"],
            device_groups=[group_guid],
            operation_id=OPERATION_ID,
        )

        self.assertEqual(result["applied"], expected)
        self.assertEqual(captured["headers"]["Idempotency-Key"], OPERATION_ID)
        self.assertEqual(
            captured["json"],
            {
                "strategy": strategy_guid,
                "peers": ["3"],
                "users": ["7"],
                "groups": [group_guid],
            },
        )

    def test_device_group_missing_and_partial_responses_fail_nonzero(self):
        groups = load_script("device-groups.py", "batch_device_groups_script")
        groups.get_group_by_name = lambda *_args: None
        with self.assertRaisesRegex(SystemExit, "1"):
            groups.add_devices(
                "https://management.example.test",
                "token",
                "missing",
                ["741000001"],
                operation_id=OPERATION_ID,
            )

        group_guid = "22222222-2222-4222-8222-222222222222"
        groups.get_group_by_name = lambda *_args: {"guid": group_guid}
        request_document = {
            "operation": "device_group_remove_devices",
            "group": group_guid,
            "devices": ["741000001", "741000002"],
        }
        partial = receipt(
            "device_group_remove_devices", request_document, {"devices": 2}
        )
        partial["applied"] = {"devices": 1}
        groups.requests.delete = lambda *_args, **_kwargs: FakeResponse(partial)

        with self.assertRaisesRegex(SystemExit, "1"):
            groups.remove_devices(
                "https://management.example.test",
                "token",
                "group",
                ["741000001", "741000002"],
                operation_id=OPERATION_ID,
            )

    def test_single_control_mutations_send_idempotency_and_empty_json_contract(self):
        users = load_script("users.py", "single_control_users_script")
        devices = load_script("devices.py", "single_control_devices_script")
        user_guid = "7"
        device_guid = "8"
        operation_ids = [
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
            "33333333-3333-4333-8333-333333333333",
            "44444444-4444-4444-8444-444444444444",
            "55555555-5555-4555-8555-555555555555",
        ]
        calls = []

        def user_post(url, *, headers, json):
            calls.append((url, headers, json))
            action = url.rsplit("/", 1)[-1]
            operation = f"user_status_{action}"
            request_document = {"operation": operation, "user": user_guid}
            return FakeResponse(
                control_receipt(
                    operation,
                    request_document,
                    {"users": 1},
                    operation_id=headers["Idempotency-Key"],
                )
            )

        def device_post(url, *, headers, json):
            calls.append((url, headers, json))
            action = url.rsplit("/", 1)[-1]
            operation = f"device_status_{action}"
            request_document = {"operation": operation, "device": device_guid}
            return FakeResponse(
                control_receipt(
                    operation,
                    request_document,
                    {"devices": 1},
                    operation_id=headers["Idempotency-Key"],
                )
            )

        def device_delete(url, *, headers, json):
            calls.append((url, headers, json))
            operation = "device_delete"
            request_document = {"operation": operation, "device": device_guid}
            return FakeResponse(
                control_receipt(
                    operation,
                    request_document,
                    {"devices": 1},
                    operation_id=headers["Idempotency-Key"],
                )
            )

        users.requests = SimpleNamespace(post=user_post)
        devices.requests = SimpleNamespace(post=device_post, delete=device_delete)

        users.disable(
            "https://management.example.test",
            "token",
            user_guid,
            "alice",
            operation_id=operation_ids[0],
        )
        users.enable(
            "https://management.example.test",
            "token",
            user_guid,
            "alice",
            operation_id=operation_ids[1],
        )
        devices.disable(
            "https://management.example.test",
            "token",
            device_guid,
            "741000001",
            operation_id=operation_ids[2],
        )
        devices.enable(
            "https://management.example.test",
            "token",
            device_guid,
            "741000001",
            operation_id=operation_ids[3],
        )
        devices.delete(
            "https://management.example.test",
            "token",
            device_guid,
            "741000001",
            operation_id=operation_ids[4],
        )

        self.assertEqual(len(calls), 5)
        for index, (_url, headers, body) in enumerate(calls):
            self.assertEqual(headers["Authorization"], "Bearer token")
            self.assertEqual(headers["Content-Type"], "application/json")
            self.assertEqual(headers["Idempotency-Key"], operation_ids[index])
            self.assertEqual(body, {})

    def test_single_control_operation_id_is_replay_safe_after_response_loss(self):
        devices = load_script("devices.py", "replay_control_devices_script")
        operation = "device_delete"
        request_document = {"operation": operation, "device": "8"}
        body = control_receipt(operation, request_document, {"devices": 1})
        calls = []

        def delete(url, *, headers, json):
            calls.append((url, headers, json))
            return FakeResponse(body)

        devices.requests.delete = delete
        first = devices.delete(
            "https://management.example.test",
            "token",
            "8",
            "741000001",
            operation_id=OPERATION_ID,
        )
        replayed = devices.delete(
            "https://management.example.test",
            "token",
            "8",
            "741000001",
            operation_id=OPERATION_ID,
        )

        self.assertEqual(first, replayed)
        self.assertEqual(
            [call[1]["Idempotency-Key"] for call in calls],
            [OPERATION_ID, OPERATION_ID],
        )

    def test_generated_control_id_and_target_are_printed_before_the_request(self):
        users = load_script("users.py", "generated_control_id_users_script")
        output = io.StringIO()

        def post(_url, *, headers, json):
            operation_id = headers["Idempotency-Key"]
            self.assertEqual(str(uuid.UUID(operation_id)), operation_id)
            self.assertIn("Operation target: user 7", output.getvalue())
            self.assertIn(f"Operation ID: {operation_id}", output.getvalue())
            self.assertEqual(json, {})
            operation = "user_status_disable"
            request_document = {"operation": operation, "user": "7"}
            return FakeResponse(
                control_receipt(
                    operation,
                    request_document,
                    {"users": 1},
                    operation_id=operation_id,
                )
            )

        users.requests = SimpleNamespace(post=post)
        with redirect_stdout(output):
            users.disable(
                "https://management.example.test",
                "token",
                "7",
                "alice",
            )

    def test_control_response_rejects_legacy_partial_and_malformed_receipts(self):
        request_document = {"operation": "device_delete", "device": "8"}
        expected = {"devices": 1}

        with self.assertRaisesRegex(SystemExit, "1"):
            check_control_response(
                FakeResponse({}),
                operation="device_delete",
                operation_id=OPERATION_ID,
                request_document=request_document,
                requested=expected,
            )

        partial = control_receipt(
            "device_delete", request_document, expected, applied={"devices": 0}
        )
        with self.assertRaisesRegex(SystemExit, "1"):
            check_control_response(
                FakeResponse(partial),
                operation="device_delete",
                operation_id=OPERATION_ID,
                request_document=request_document,
                requested=expected,
            )

        rejected = control_receipt(
            "device_delete",
            request_document,
            expected,
            applied={"devices": 0},
            error="Device not found",
        )
        with self.assertRaisesRegex(SystemExit, "1"):
            check_control_response(
                FakeResponse(rejected, status_code=404),
                operation="device_delete",
                operation_id=OPERATION_ID,
                request_document=request_document,
                requested=expected,
            )

    def test_single_operation_id_cannot_be_reused_for_multiple_targets(self):
        users = load_script("users.py", "multi_target_users_script")
        users.view = lambda *_args: [
            {"guid": "7", "name": "alice"},
            {"guid": "8", "name": "bob"},
        ]
        argv = [
            "users.py",
            "disable",
            "--url",
            "https://management.example.test",
            "--token",
            "token",
            "--operation-id",
            OPERATION_ID,
        ]
        with patch.object(sys, "argv", argv), self.assertRaisesRegex(SystemExit, "1"):
            users.main()

    def test_multi_target_control_generates_one_operation_id_per_target(self):
        users = load_script("users.py", "multi_target_generated_users_script")
        users.view = lambda *_args: [
            {"guid": "7", "name": "alice"},
            {"guid": "8", "name": "bob"},
        ]
        calls = []

        def post(url, *, headers, json):
            user_guid = url.split("/")[-2]
            operation_id = headers["Idempotency-Key"]
            calls.append((user_guid, operation_id, json))
            operation = "user_status_disable"
            request_document = {"operation": operation, "user": user_guid}
            return FakeResponse(
                control_receipt(
                    operation,
                    request_document,
                    {"users": 1},
                    operation_id=operation_id,
                )
            )

        users.requests = SimpleNamespace(post=post)
        argv = [
            "users.py",
            "disable",
            "--url",
            "https://management.example.test",
            "--token",
            "token",
        ]

        with (
            patch.object(sys, "argv", argv),
            patch("builtins.input", return_value="Y"),
        ):
            users.main()

        self.assertEqual([call[0] for call in calls], ["7", "8"])
        self.assertEqual([call[2] for call in calls], [{}, {}])
        self.assertEqual(len({call[1] for call in calls}), 2)

    def test_deleted_device_receipt_can_be_replayed_by_exact_guid_without_lookup(self):
        devices = load_script("devices.py", "deleted_device_replay_script")
        devices.view = lambda *_args: self.fail("replay must not depend on inventory")
        request_document = {"operation": "device_delete", "device": "8"}
        body = control_receipt("device_delete", request_document, {"devices": 1})
        calls = []

        def delete(url, *, headers, json):
            calls.append((url, headers, json))
            return FakeResponse(body)

        devices.requests = SimpleNamespace(delete=delete)
        argv = [
            "devices.py",
            "delete",
            "--url",
            "https://management.example.test",
            "--token",
            "token",
            "--guid",
            "8",
            "--operation-id",
            OPERATION_ID,
        ]

        with patch.object(sys, "argv", argv):
            devices.main()

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "https://management.example.test/api/devices/8")
        self.assertEqual(calls[0][1]["Idempotency-Key"], OPERATION_ID)
        self.assertEqual(calls[0][2], {})


if __name__ == "__main__":
    unittest.main()

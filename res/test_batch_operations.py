import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from batch_operations import check_batch_response, document_digest

RES_DIR = Path(__file__).resolve().parent
OPERATION_ID = "11111111-1111-4111-8111-111111111111"


class FakeResponse:
    def __init__(self, body, status_code=200):
        self._body = body
        self.status_code = status_code
        self.text = str(body)

    def json(self):
        return self._body


def receipt(operation, request_document, requested):
    return {
        "result": "OK",
        "management_operation_receipt_version": 1,
        "operation_id": OPERATION_ID,
        "operation": operation,
        "operation_generation": 7,
        "request_digest": document_digest(request_document),
        "result_digest": "a" * 64,
        "requested": requested,
        "applied": requested,
    }


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


if __name__ == "__main__":
    unittest.main()

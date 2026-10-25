import importlib.util
import io
import sys
import unittest
import uuid
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import camellia_remote_admin
from camellia_remote_admin.batch_operations import (
    check_batch_response,
    check_control_response,
    document_digest,
    public_intent_digest,
    public_intent_document,
    recover_operation,
    replayable_request_document,
)

PACKAGE_DIR = Path(camellia_remote_admin.__file__).resolve().parent
OPERATION_ID = "11111111-1111-4111-8111-111111111111"


def request_operation_id(headers):
    wire_key = headers["Idempotency-Key"]
    if not wire_key.startswith("v2:"):
        raise AssertionError("Expected receipt-v2 wire key")
    return wire_key[3:]


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
        "management_operation_receipt_version": 2,
        "operation_id": operation_id,
        "operation": operation,
        "operation_generation": 7,
        "request_digest": public_intent_digest(request_document),
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
        body["code"] = "management_operation_failed"
        body["message"] = error
        body["retryable"] = False
    return body


def load_script(filename, module_name):
    module_name = module_name.replace(".", "_").replace("-", "_")
    spec = importlib.util.spec_from_file_location(
        "camellia_remote_admin." + module_name, PACKAGE_DIR / filename
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if hasattr(module, "transport"):
        # Mutating a script fake must not replace the shared transport for later tests.
        module.transport = SimpleNamespace(
            **{
                name: getattr(module.transport, name)
                for name in (
                    "get",
                    "post",
                    "put",
                    "patch",
                    "delete",
                    "configure",
                    "add_options",
                )
            }
        )
    return module


class BatchOperationReceiptTests(unittest.TestCase):
    def test_operation_receipt_can_be_recovered_without_replaying_mutation(self):
        request_document = {"operation": "share_link_create", "peers": ["3"]}
        body = receipt(
            "share_link_create",
            request_document,
            {"share_links": 1},
        )
        body["token"] = "recovered-sensitive-token"
        captured = {}

        def get(url, *, headers):
            captured.update(url=url, headers=headers)
            return FakeResponse(
                {
                    "original_status_code": 200,
                    "receipt": body,
                }
            )

        with patch(
            "camellia_remote_admin.batch_operations.transport.get", side_effect=get
        ):
            recovered = recover_operation(
                "https://management.example.test/",
                "token",
                OPERATION_ID,
            )

        self.assertEqual(recovered["receipt"]["token"], "recovered-sensitive-token")
        self.assertEqual(
            captured["url"],
            f"https://management.example.test/api/management-operations/{OPERATION_ID}",
        )
        self.assertEqual(captured["headers"], {"Authorization": "Bearer token"})

    def test_retired_operation_recovery_stays_unknown_and_never_reposts(self):
        with (
            patch(
                "camellia_remote_admin.batch_operations.transport.get",
                return_value=FakeResponse(
                    {"code": "operation_receipt_retired"}, status_code=410
                ),
            ) as read,
            patch("camellia_remote_admin.batch_operations.transport.post") as write,
            self.assertRaises(SystemExit) as rejected,
        ):
            recover_operation("https://management.example.test", "token", OPERATION_ID)
        self.assertEqual(rejected.exception.code, 1)
        self.assertIn("retired", rejected.exception.message)
        read.assert_called_once()
        write.assert_not_called()

    def test_device_group_update_binds_operation_and_generation(self):
        groups = load_script("device_groups.py", "state040_device_groups_script")
        group_guid = "22222222-2222-4222-8222-222222222222"
        generation = 4
        payload = {"note": "updated"}
        request_document = {
            "operation": "device_group_update",
            "group": group_guid,
            "data": payload,
            "expected_generation": generation,
        }
        captured = {}
        groups.get_group_by_name = lambda *_args: {
            "guid": group_guid,
            "mutation_generation": generation,
        }

        def patch_request(url, *, headers, json):
            captured.update(url=url, headers=headers, json=json)
            return FakeResponse(
                control_receipt(
                    "device_group_update",
                    request_document,
                    {"groups": 1},
                )
            )

        groups.transport.patch = patch_request
        result = groups.update_group(
            "https://management.example.test",
            "token",
            "group",
            note="updated",
            operation_id=OPERATION_ID,
        )

        self.assertEqual(result["applied"], {"groups": 1})
        self.assertEqual(captured["headers"]["Idempotency-Key"], f"v2:{OPERATION_ID}")
        self.assertEqual(captured["headers"]["If-Match"], '"4"')
        self.assertEqual(captured["json"], payload)

    def test_strategy_status_binds_operation_and_generation(self):
        strategies = load_script("strategies.py", "state040_strategy_status_script")
        strategy_guid = "33333333-3333-4333-8333-333333333333"
        generation = 2
        request_document = {
            "operation": "strategy_status",
            "strategy": strategy_guid,
            "enabled": False,
            "expected_generation": generation,
        }
        captured = {}
        strategies.get_strategy_by_name = lambda *_args: {
            "guid": strategy_guid,
            "mutation_generation": generation,
        }

        def put(url, *, headers, json):
            captured.update(url=url, headers=headers, json=json)
            return FakeResponse(
                control_receipt(
                    "strategy_status",
                    request_document,
                    {"strategies": 1},
                )
            )

        strategies.transport.put = put
        result = strategies.disable_strategy(
            "https://management.example.test",
            "token",
            "locked-down",
            operation_id=OPERATION_ID,
        )

        self.assertEqual(result["applied"], {"strategies": 1})
        self.assertEqual(captured["headers"]["If-Match"], '"2"')
        self.assertIs(captured["json"], False)

    def test_address_book_peer_mutation_binds_body_generation_and_operation(self):
        address_books = load_script("address_books.py", "state040_address_book_script")
        profile_guid = "state040-client-profile"
        payload = {"id": "741000001", "note": "note", "alias": "alias"}
        path = f"/api/ab/peer/add/{profile_guid}"
        request_document = replayable_request_document(
            "address_book_peer_add",
            "POST",
            path,
            payload,
            expected_generation=5,
        )
        captured = {}

        def post(url, *, headers, json):
            captured.update(url=url, headers=headers, json=json)
            return FakeResponse(
                control_receipt(
                    "address_book_peer_add",
                    request_document,
                    {"mutations": 1},
                )
            )

        address_books.transport.post = post
        result = address_books.add_peer(
            "https://management.example.test",
            "token",
            profile_guid,
            "741000001",
            alias="alias",
            note="note",
            operation_id=OPERATION_ID,
            expected_generation=5,
        )

        self.assertEqual(result["applied"], {"mutations": 1})
        self.assertEqual(captured["headers"]["Idempotency-Key"], f"v2:{OPERATION_ID}")
        self.assertEqual(captured["headers"]["If-Match"], '"5"')
        self.assertEqual(captured["json"], payload)

    def test_address_book_profile_create_projects_secret_in_public_request_proof(self):
        address_books = load_script(
            "address_books.py", "state040_address_book_profile_script"
        )
        password = "state040-client-profile-secret"
        request_document = {
            "operation": "address_book_profile_create",
            "name": "shared-book",
            "note": "note",
            "info": None,
            "has_default_password": True,
            "default_password": password,
        }
        captured = {}

        def post(url, *, headers, json):
            captured.update(url=url, headers=headers, json=json)
            return FakeResponse(
                control_receipt(
                    "address_book_profile_create",
                    request_document,
                    {"profiles": 1},
                )
            )

        address_books.transport.post = post
        result = address_books.add_shared_ab(
            "https://management.example.test",
            "token",
            " shared-book ",
            note="note",
            password=password,
            operation_id=OPERATION_ID,
        )

        self.assertEqual(result["applied"], {"profiles": 1})
        self.assertEqual(captured["json"]["default_password"], password)
        self.assertEqual(captured["headers"]["Idempotency-Key"], f"v2:{OPERATION_ID}")

    def test_user_create_digest_and_device_assign_generation_match_server_contract(
        self,
    ):
        users = load_script("users.py", "state040_user_create_script")
        devices = load_script("devices.py", "state040_device_assign_script")
        password = "state040-client-secret"
        user_document = {
            "operation": "user_create",
            "username": "new-user",
            "password": password,
            "email": "",
            "note": "",
            "group_name": "operators",
        }
        users.transport.post = lambda *_args, **_kwargs: FakeResponse(
            control_receipt("user_create", user_document, {"users": 1})
        )
        user_result = users.new_user(
            "https://management.example.test",
            "token",
            "new-user",
            password,
            "operators",
            operation_id=OPERATION_ID,
        )
        self.assertEqual(user_result["applied"], {"users": 1})

        device_document = {
            "operation": "device_assign",
            "device": "8",
            "type": "note",
            "value": "updated",
            "expected_generation": 3,
        }
        captured = {}

        def post_device(url, *, headers, json):
            captured.update(url=url, headers=headers, json=json)
            return FakeResponse(
                control_receipt(
                    "device_assign",
                    device_document,
                    {"devices": 1},
                )
            )

        devices.transport.post = post_device
        device_result = devices.assign(
            "https://management.example.test",
            "token",
            "8",
            "741000001",
            "note",
            "updated",
            operation_id=OPERATION_ID,
            expected_generation=3,
        )
        self.assertEqual(device_result["applied"], {"devices": 1})
        self.assertEqual(captured["headers"]["If-Match"], '"3"')

    def test_device_address_book_assignment_projects_secret_in_public_receipt(self):
        devices = load_script("devices.py", "state040_device_ab_assign_script")
        password = "state040-address-book-password"
        value = {
            "address_book_name": "shared",
            "address_book_tag": "production",
            "address_book_alias": "desk",
            "address_book_password": password,
            "address_book_note": "note",
        }
        receipt_value = {
            key: nested_value
            for key, nested_value in value.items()
            if key != "address_book_password"
        }
        receipt_value.update(
            has_address_book_password=True,
            address_book_password=password,
        )
        request_document = {
            "operation": "device_assign",
            "device": "8",
            "type": "ab",
            "value": receipt_value,
            "expected_generation": 3,
        }
        captured = {}

        def post(url, *, headers, json):
            captured.update(url=url, headers=headers, json=json)
            return FakeResponse(
                control_receipt(
                    "device_assign",
                    request_document,
                    {"devices": 1},
                )
            )

        devices.transport.post = post
        result = devices.assign(
            "https://management.example.test",
            "token",
            "8",
            "741000001",
            "ab",
            "shared,production,desk,state040-address-book-password,note",
            operation_id=OPERATION_ID,
            expected_generation=3,
        )

        self.assertEqual(result["applied"], {"devices": 1})
        self.assertEqual(captured["json"]["value"]["address_book_password"], password)

    def test_cross_repository_canonical_request_digest_vector(self):
        self.assertEqual(
            document_digest(
                {
                    "operation": "strategy_assign",
                    "strategy": None,
                    "peers": ["3"],
                    "users": ["7"],
                    "groups": [],
                    "expected_generations": {
                        "devices": {"3": 0},
                        "users": {"7": 0},
                        "groups": {},
                    },
                }
            ),
            "26c6b44fa09cf1d964dfb7a78de7ca95e65628b04332176243de9f4213649721",
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

    def test_public_request_proof_cannot_distinguish_password_guesses_but_binds_public_targets(
        self,
    ):
        first = {
            "operation": "user_create",
            "username": "private-intent",
            "password": "SYNTHETIC-FIRST",
        }
        second = {**first, "password": "SYNTHETIC-DIFFERENT-AND-LONGER"}
        self.assertEqual(public_intent_digest(first), public_intent_digest(second))
        self.assertNotIn("SYNTHETIC-FIRST", str(public_intent_document(first)))
        self.assertNotEqual(
            public_intent_digest(first),
            public_intent_digest({**first, "username": "other"}),
        )
        self.assertNotEqual(
            public_intent_digest(first), public_intent_digest({**first, "password": ""})
        )

    def test_old_receipt_version_is_not_accepted_as_v2_completion(self):
        document = {"operation": "users_force_logout", "users": ["7"]}
        body = receipt("users_force_logout", document, {"users": 1})
        body["management_operation_receipt_version"] = 1
        with self.assertRaisesRegex(SystemExit, "^1$"):
            check_batch_response(
                FakeResponse(body),
                operation="users_force_logout",
                operation_id=OPERATION_ID,
                request_document=document,
                requested={"users": 1},
            )

    def test_personal_peer_wire_hash_cannot_be_guessed_from_public_request_proof(self):
        first = {"body": {"id": "123", "hash": "SYNTHETIC-PERSONAL-HASH-A"}}
        second = {"body": {"id": "123", "hash": "SYNTHETIC-PERSONAL-HASH-B"}}
        self.assertEqual(public_intent_digest(first), public_intent_digest(second))
        self.assertNotIn("SYNTHETIC-PERSONAL-HASH", str(public_intent_document(first)))

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

        with self.assertRaisesRegex(SystemExit, "^4$"):
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
        with self.assertRaisesRegex(SystemExit, "^1$"):
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

        users.transport.post = post
        result = users.force_logout(
            "https://management.example.test",
            "token",
            ["7", "9"],
            operation_id=OPERATION_ID,
        )

        self.assertEqual(result["applied"], {"users": 2})
        self.assertEqual(captured["headers"]["Idempotency-Key"], f"v2:{OPERATION_ID}")
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

        with patch.object(sys, "argv", argv), self.assertRaisesRegex(SystemExit, "^3$"):
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
            "expected_generations": {
                "devices": {"3": 2},
                "users": {"7": 4},
                "groups": {group_guid: 6},
            },
        }
        expected = {"devices": 1, "users": 1, "groups": 1}
        captured = {}
        strategies.get_strategy_by_name = lambda *_args: {"guid": strategy_guid}
        strategies.get_device_target = lambda *_args: {
            "guid": "3",
            "mutation_generation": 2,
        }
        strategies.get_user_target = lambda *_args: {
            "guid": "7",
            "mutation_generation": 4,
        }
        strategies.get_device_group_target = lambda *_args: {
            "guid": group_guid,
            "mutation_generation": 6,
        }

        def post(url, *, headers, json):
            captured.update(url=url, headers=headers, json=json)
            return FakeResponse(receipt("strategy_assign", request_document, expected))

        strategies.transport.post = post
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
        self.assertEqual(captured["headers"]["Idempotency-Key"], f"v2:{OPERATION_ID}")
        self.assertEqual(
            captured["json"],
            {
                "strategy": strategy_guid,
                "peers": ["3"],
                "users": ["7"],
                "groups": [group_guid],
                "expected_generations": {
                    "devices": {"3": 2},
                    "users": {"7": 4},
                    "groups": {group_guid: 6},
                },
            },
        )

    def test_device_group_missing_and_partial_responses_fail_nonzero(self):
        groups = load_script("device_groups.py", "batch_device_groups_script")
        groups.get_group_by_name = lambda *_args: None
        with self.assertRaisesRegex(SystemExit, "^3$"):
            groups.add_devices(
                "https://management.example.test",
                "token",
                "missing",
                ["741000001"],
                operation_id=OPERATION_ID,
            )

        group_guid = "22222222-2222-4222-8222-222222222222"
        generation = 3
        groups.get_group_by_name = lambda *_args: {
            "guid": group_guid,
            "mutation_generation": generation,
        }
        request_document = {
            "operation": "device_group_remove_devices",
            "group": group_guid,
            "devices": ["741000001", "741000002"],
            "expected_generation": generation,
        }
        partial = receipt(
            "device_group_remove_devices", request_document, {"devices": 2}
        )
        partial["applied"] = {"devices": 1}
        groups.transport.delete = lambda *_args, **_kwargs: FakeResponse(partial)

        with self.assertRaisesRegex(SystemExit, "^4$"):
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
            request_document = {
                "operation": operation,
                "user": user_guid,
                "expected_generation": 0,
            }
            return FakeResponse(
                control_receipt(
                    operation,
                    request_document,
                    {"users": 1},
                    operation_id=request_operation_id(headers),
                )
            )

        def device_post(url, *, headers, json):
            calls.append((url, headers, json))
            action = url.rsplit("/", 1)[-1]
            operation = f"device_status_{action}"
            request_document = {
                "operation": operation,
                "device": device_guid,
                "expected_generation": 0,
            }
            return FakeResponse(
                control_receipt(
                    operation,
                    request_document,
                    {"devices": 1},
                    operation_id=request_operation_id(headers),
                )
            )

        def device_delete(url, *, headers, json):
            calls.append((url, headers, json))
            operation = "device_delete"
            request_document = {
                "operation": operation,
                "device": device_guid,
                "expected_generation": 0,
            }
            return FakeResponse(
                control_receipt(
                    operation,
                    request_document,
                    {"devices": 1},
                    operation_id=request_operation_id(headers),
                )
            )

        users.transport = SimpleNamespace(post=user_post)
        devices.transport = SimpleNamespace(post=device_post, delete=device_delete)

        users.disable(
            "https://management.example.test",
            "token",
            user_guid,
            "alice",
            operation_id=operation_ids[0],
            expected_generation=0,
        )
        users.enable(
            "https://management.example.test",
            "token",
            user_guid,
            "alice",
            operation_id=operation_ids[1],
            expected_generation=0,
        )
        devices.disable(
            "https://management.example.test",
            "token",
            device_guid,
            "741000001",
            operation_id=operation_ids[2],
            expected_generation=0,
        )
        devices.enable(
            "https://management.example.test",
            "token",
            device_guid,
            "741000001",
            operation_id=operation_ids[3],
            expected_generation=0,
        )
        devices.delete(
            "https://management.example.test",
            "token",
            device_guid,
            "741000001",
            operation_id=operation_ids[4],
            expected_generation=0,
        )

        self.assertEqual(len(calls), 5)
        for index, (_url, headers, body) in enumerate(calls):
            self.assertEqual(headers["Authorization"], "Bearer token")
            self.assertEqual(headers["Content-Type"], "application/json")
            self.assertEqual(headers["Idempotency-Key"], f"v2:{operation_ids[index]}")
            self.assertEqual(headers["If-Match"], '"0"')
            self.assertEqual(body, {})

    def test_single_control_operation_id_is_replay_safe_after_response_loss(self):
        devices = load_script("devices.py", "replay_control_devices_script")
        operation = "device_delete"
        request_document = {
            "operation": operation,
            "device": "8",
            "expected_generation": 0,
        }
        body = control_receipt(operation, request_document, {"devices": 1})
        calls = []

        def delete(url, *, headers, json):
            calls.append((url, headers, json))
            return FakeResponse(body)

        devices.transport.delete = delete
        first = devices.delete(
            "https://management.example.test",
            "token",
            "8",
            "741000001",
            operation_id=OPERATION_ID,
            expected_generation=0,
        )
        replayed = devices.delete(
            "https://management.example.test",
            "token",
            "8",
            "741000001",
            operation_id=OPERATION_ID,
            expected_generation=0,
        )

        self.assertEqual(first, replayed)
        self.assertEqual(
            [call[1]["Idempotency-Key"] for call in calls],
            [f"v2:{OPERATION_ID}", f"v2:{OPERATION_ID}"],
        )

    def test_generated_control_id_and_target_are_printed_before_the_request(self):
        users = load_script("users.py", "generated_control_id_users_script")
        output = io.StringIO()

        def post(_url, *, headers, json):
            operation_id = request_operation_id(headers)
            self.assertEqual(str(uuid.UUID(operation_id)), operation_id)
            self.assertIn("Operation target: user 7", output.getvalue())
            self.assertIn(f"Operation ID: {operation_id}", output.getvalue())
            self.assertEqual(json, {})
            operation = "user_status_disable"
            request_document = {
                "operation": operation,
                "user": "7",
                "expected_generation": 0,
            }
            return FakeResponse(
                control_receipt(
                    operation,
                    request_document,
                    {"users": 1},
                    operation_id=operation_id,
                )
            )

        users.transport = SimpleNamespace(post=post, configure=lambda _args: None)
        with redirect_stdout(output):
            users.disable(
                "https://management.example.test",
                "token",
                "7",
                "alice",
                expected_generation=0,
            )

    def test_control_response_rejects_legacy_partial_and_malformed_receipts(self):
        request_document = {"operation": "device_delete", "device": "8"}
        expected = {"devices": 1}

        with self.assertRaisesRegex(SystemExit, "^1$"):
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
        with self.assertRaisesRegex(SystemExit, "^4$"):
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
        with self.assertRaisesRegex(SystemExit, "^5$"):
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
            {"guid": "7", "name": "alice", "mutation_generation": 0},
            {"guid": "8", "name": "bob", "mutation_generation": 0},
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
        with patch.object(sys, "argv", argv), self.assertRaisesRegex(SystemExit, "^2$"):
            users.main()

    def test_multi_target_control_generates_one_operation_id_per_target(self):
        users = load_script("users.py", "multi_target_generated_users_script")
        users.view = lambda *_args: [
            {"guid": "7", "name": "alice", "mutation_generation": 0},
            {"guid": "8", "name": "bob", "mutation_generation": 0},
        ]
        calls = []

        def post(url, *, headers, json):
            user_guid = url.split("/")[-2]
            operation_id = request_operation_id(headers)
            calls.append((user_guid, operation_id, json))
            operation = "user_status_disable"
            request_document = {
                "operation": operation,
                "user": user_guid,
                "expected_generation": 0,
            }
            return FakeResponse(
                control_receipt(
                    operation,
                    request_document,
                    {"users": 1},
                    operation_id=operation_id,
                )
            )

        users.transport = SimpleNamespace(post=post, configure=lambda _args: None)
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
        request_document = {
            "operation": "device_delete",
            "device": "8",
            "expected_generation": 0,
        }
        body = control_receipt("device_delete", request_document, {"devices": 1})
        calls = []

        def delete(url, *, headers, json):
            calls.append((url, headers, json))
            return FakeResponse(body)

        devices.transport = SimpleNamespace(delete=delete, configure=lambda _args: None)
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
            "--expected-generation",
            "0",
        ]

        with patch.object(sys, "argv", argv):
            devices.main()

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "https://management.example.test/api/devices/8")
        self.assertEqual(calls[0][1]["Idempotency-Key"], f"v2:{OPERATION_ID}")
        self.assertEqual(calls[0][2], {})


if __name__ == "__main__":
    unittest.main()

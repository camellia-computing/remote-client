import hashlib
import json
import re
import uuid

import requests

MANAGEMENT_OPERATION_RECEIPT_VERSION = 1
MAX_MANAGEMENT_MODEL_PK = (1 << 63) - 1
_DIGEST_RE = re.compile(r"[0-9a-f]{64}")
_MACHINE_CODE_RE = re.compile(r"[a-z][a-z0-9_]{0,63}")


def fail(message):
    print(f"Error: {message}")
    raise SystemExit(1)


def canonical_document(value):
    try:
        return json.dumps(
            value,
            sort_keys=True,
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ValueError("Batch operation document is not canonical JSON") from exc


def document_digest(value):
    return hashlib.sha256(canonical_document(value)).hexdigest()


def canonical_operation_id(value=None):
    if value is None:
        return str(uuid.uuid4())
    if not isinstance(value, str) or len(value) != 36 or not value.isascii():
        fail("operation ID must be a canonical UUID")
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        fail("operation ID must be a canonical UUID")
    if str(parsed) != value.lower() or parsed.version != 4:
        fail("operation ID must be a canonical random UUIDv4")
    return str(parsed)


def canonical_uuid(value, label):
    if not isinstance(value, str) or len(value) != 36 or not value.isascii():
        fail(f"{label} is not a canonical UUID")
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        fail(f"{label} is not a canonical UUID")
    if str(parsed) != value.lower():
        fail(f"{label} is not a canonical UUID")
    return str(parsed)


def canonical_model_pk(value, label):
    if (
        not isinstance(value, str)
        or not value
        or not value.isascii()
        or not value.isdigit()
        or value.startswith("0")
    ):
        fail(f"{label} is not a canonical positive identifier")
    parsed = int(value)
    if parsed > MAX_MANAGEMENT_MODEL_PK:
        fail(f"{label} is not a canonical positive identifier")
    return value


def require_unique(values, label):
    seen = set()
    for value in values:
        if not isinstance(value, str) or not value:
            fail(f"{label} targets must be non-empty text identifiers")
        if value in seen:
            fail(f"duplicate {label} targets are not allowed")
        seen.add(value)


def operation_headers(token, operation_id, expected_generation=None):
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Idempotency-Key": operation_id,
    }
    if expected_generation is not None:
        if type(expected_generation) is not int or expected_generation < 0:
            fail("expected generation must be a non-negative integer")
        headers["If-Match"] = f'"{expected_generation}"'
    return headers


def required_generation(value):
    if type(value) is not int or value < 0:
        fail("expected generation is required for this mutation")
    return value


def recover_operation(url, token, operation_id):
    """Recover an immutable receipt without replaying the mutation request."""

    operation_id = canonical_operation_id(operation_id)
    response = requests.get(
        f"{url.rstrip('/')}/api/management-operations/{operation_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    if response.status_code != 200:
        fail(f"HTTP {response.status_code}: {response.text}")
    try:
        envelope = response.json()
    except ValueError:
        fail("management operation recovery response is not JSON")
    receipt = envelope.get("receipt") if isinstance(envelope, dict) else None
    original_status = envelope.get("original_status_code") if isinstance(envelope, dict) else None
    if (
        type(original_status) is not int
        or not 200 <= original_status < 500
        or not isinstance(receipt, dict)
        or receipt.get("operation_id") != operation_id
        or receipt.get("management_operation_receipt_version")
        != MANAGEMENT_OPERATION_RECEIPT_VERSION
        or not isinstance(receipt.get("operation"), str)
        or not receipt["operation"]
        or not isinstance(receipt.get("request_digest"), str)
        or _DIGEST_RE.fullmatch(receipt["request_digest"]) is None
        or not isinstance(receipt.get("result_digest"), str)
        or _DIGEST_RE.fullmatch(receipt["result_digest"]) is None
        or type(receipt.get("operation_generation")) is not int
        or receipt["operation_generation"] <= 0
        or not isinstance(receipt.get("requested"), dict)
        or not isinstance(receipt.get("applied"), dict)
    ):
        fail("management operation recovery receipt is invalid")
    return {"original_status_code": original_status, "receipt": receipt}


def replayable_request_document(
    operation, method, path, payload, *, expected_generation=None, query=None
):
    """Build the digest input used by replayable Address Book endpoints."""

    try:
        body = json.dumps(payload, allow_nan=False).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ValueError("Mutation payload is not JSON serializable") from exc
    args = {}
    for key, values in (query or {}).items():
        values = values if isinstance(values, list) else [values]
        args[str(key)] = sorted(str(value) for value in values)
    return {
        "operation": operation,
        "method": method.upper(),
        "path": path,
        "args": {key: args[key] for key in sorted(args)},
        "body_sha256": hashlib.sha256(body).hexdigest(),
        "expected_generation": expected_generation,
    }


def check_batch_response(
    response, *, operation, operation_id, request_document, requested
):
    if response.status_code != 200:
        fail(f"HTTP {response.status_code}: {response.text}")
    try:
        body = response.json()
    except ValueError:
        fail("management batch response is not JSON")
    expected_digest = document_digest(request_document)
    expected_keys = set(requested)
    valid = (
        isinstance(body, dict)
        and body.get("result") == "OK"
        and "error" not in body
        and type(body.get("management_operation_receipt_version")) is int
        and body["management_operation_receipt_version"]
        == MANAGEMENT_OPERATION_RECEIPT_VERSION
        and body.get("operation") == operation
        and body.get("operation_id") == operation_id
        and body.get("request_digest") == expected_digest
        and isinstance(body.get("result_digest"), str)
        and _DIGEST_RE.fullmatch(body["result_digest"]) is not None
        and isinstance(body.get("operation_generation"), int)
        and not isinstance(body["operation_generation"], bool)
        and body["operation_generation"] > 0
        and isinstance(body.get("requested"), dict)
        and isinstance(body.get("applied"), dict)
        and set(body["requested"]) == expected_keys
        and set(body["applied"]) == expected_keys
        and all(
            type(count) is int and count >= 0 for count in body["requested"].values()
        )
        and all(type(count) is int and count >= 0 for count in body["applied"].values())
        and body["requested"] == requested
        and body["applied"] == requested
    )
    if not valid:
        fail("management batch response receipt does not match the request")
    return body


def _receipt_envelope_matches(
    body, *, operation, operation_id, request_document, requested
):
    """Validate the fields common to every management mutation receipt."""

    if not isinstance(body, dict):
        return False
    expected_digest = document_digest(request_document)
    return not (
        type(body.get("management_operation_receipt_version")) is not int
        or body["management_operation_receipt_version"]
        != MANAGEMENT_OPERATION_RECEIPT_VERSION
        or body.get("operation") != operation
        or body.get("operation_id") != operation_id
        or body.get("request_digest") != expected_digest
        or not isinstance(body.get("result_digest"), str)
        or _DIGEST_RE.fullmatch(body["result_digest"]) is None
        or not isinstance(body.get("operation_generation"), int)
        or isinstance(body["operation_generation"], bool)
        or body["operation_generation"] <= 0
        or not isinstance(body.get("requested"), dict)
        or not isinstance(body.get("applied"), dict)
        or set(body["requested"]) != set(requested)
        or set(body["applied"]) != set(requested)
        or body["requested"] != requested
        or any(
            type(count) is not int or count < 0 for count in body["requested"].values()
        )
        or any(
            type(count) is not int or count < 0 or count > requested[key]
            for key, count in body["applied"].items()
        )
    )


def check_control_response(
    response, *, operation, operation_id, request_document, requested
):
    """Fail closed on a single-target control mutation response.

    Control endpoints persist a receipt for both successful and durable
    rejected mutations.  A legacy/partial/malformed body is never treated as
    success, even when the HTTP status is 200.
    """

    try:
        body = response.json()
    except (AttributeError, ValueError):
        fail("management control response is not JSON")

    if not _receipt_envelope_matches(
        body,
        operation=operation,
        operation_id=operation_id,
        request_document=request_document,
        requested=requested,
    ):
        fail("management control response receipt is invalid")

    if response.status_code == 200:
        if (
            body.get("result") != "OK"
            or "error" in body
            or body["applied"] != requested
        ):
            fail("management control response receipt is not fully applied")
        return body

    code = body.get("code")
    message = body.get("message")
    retryable = body.get("retryable")
    if (
        not isinstance(code, str)
        or _MACHINE_CODE_RE.fullmatch(code) is None
        or not isinstance(message, str)
        or not message
        or type(retryable) is not bool
        or body.get("result") == "OK"
        or body["applied"] == requested
    ):
        fail("management control error receipt is invalid")
    fail(f"HTTP {response.status_code} [{code}]: {message}")

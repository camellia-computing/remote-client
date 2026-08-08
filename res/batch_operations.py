import hashlib
import json
import re
import uuid

MANAGEMENT_OPERATION_RECEIPT_VERSION = 1
MAX_MANAGEMENT_MODEL_PK = (1 << 63) - 1
_DIGEST_RE = re.compile(r"[0-9a-f]{64}")


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
    if str(parsed) != value.lower():
        fail("operation ID must be a canonical UUID")
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


def operation_headers(token, operation_id):
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Idempotency-Key": operation_id,
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

    error = body.get("error")
    if not isinstance(error, str) or not error or body["applied"] == requested:
        fail("management control error receipt is invalid")
    fail(f"HTTP {response.status_code}: {error}")

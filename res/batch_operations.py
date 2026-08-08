import hashlib
import json
import re
import uuid

MANAGEMENT_OPERATION_RECEIPT_VERSION = 1
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

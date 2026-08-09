"""Strict consumer for Management response contract v1."""

import re

SCHEMA_HEADER = "X-Camellia-Response-Schema"
KIND_HEADER = "X-Camellia-Response-Kind"
SCHEMA_VERSION = 1
_MACHINE_CODE = re.compile(r"[a-z][a-z0-9_]{0,63}\Z")


class ManagementResponseError(RuntimeError):
    def __init__(self, status_code, code, message, retryable):
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.retryable = retryable


def _require_header(response):
    if response.headers.get(SCHEMA_HEADER) != str(SCHEMA_VERSION):
        raise ValueError("Unsupported Management response schema")
    content_type = response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
    if content_type != "application/json":
        raise ValueError("Invalid Management response content type")


def response_payload(response):
    _require_header(response)
    try:
        body = response.json()
    except ValueError as exc:
        raise ValueError("Invalid Management JSON response") from exc
    if not isinstance(body, dict) or body.get("response_schema_version") != SCHEMA_VERSION:
        raise ValueError("Invalid Management response object")
    kind = response.headers.get(KIND_HEADER)
    expected_kind = (
        "error"
        if response.status_code >= 400
        else "pending"
        if response.status_code == 202 and body.get("pending") is True
        else "accepted"
        if response.status_code == 202
        else "success"
    )
    if kind != expected_kind:
        raise ValueError("Invalid Management response kind")
    return body


def response_object(response):
    body = response_payload(response)
    if response.status_code >= 400:
        code = body.get("code")
        message = body.get("message")
        retryable = body.get("retryable")
        if (
            not isinstance(code, str)
            or _MACHINE_CODE.fullmatch(code) is None
            or not isinstance(message, str)
            or not 1 <= len(message) <= 256
            or not isinstance(retryable, bool)
        ):
            raise ValueError("Invalid Management error response")
        raise ManagementResponseError(response.status_code, code, message, retryable)
    return body


def response_list(response):
    _require_header(response)
    if response.status_code >= 400:
        response_object(response)
    try:
        body = response.json()
    except ValueError as exc:
        raise ValueError("Invalid Management JSON response") from exc
    if not isinstance(body, list):
        raise ValueError("Invalid Management response list")
    if response.status_code != 200 or response.headers.get(KIND_HEADER) != "success":
        raise ValueError("Invalid Management response kind")
    return body


def response_any(response):
    """Decode a versioned object/list response, or a canonical empty mutation."""
    if response.status_code == 204:
        require_empty_success(response)
        return None
    # Decode the bounded JSON once only to select the endpoint shape.  The
    # actual validation remains in response_object/response_list so errors
    # cannot fall through as an arbitrary dict or human text.
    _require_header(response)
    try:
        body = response.json()
    except ValueError as exc:
        raise ValueError("Invalid Management JSON response") from exc
    if isinstance(body, list):
        return response_list(response)
    return response_object(response)


def require_empty_success(response):
    _require_header(response)
    if response.status_code >= 400:
        response_object(response)
    if response.status_code != 204 or response.headers.get(KIND_HEADER) != "empty" or response.content:
        raise ValueError("Invalid Management empty response")

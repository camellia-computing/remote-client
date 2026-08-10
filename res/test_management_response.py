import unittest

from management_response import (
    ManagementResponseError,
    require_empty_success,
    response_object,
)


class FakeResponse:
    def __init__(self, status_code, body, *, kind="success", schema="1", content=b"fixture"):
        self.status_code = status_code
        self._body = body
        self.headers = {
            "X-Camellia-Response-Schema": schema,
            "X-Camellia-Response-Kind": kind,
            "Content-Type": "application/json",
        }
        self.content = content

    def json(self):
        return self._body


class ManagementResponseContractTests(unittest.TestCase):
    def test_accepts_v1_object_and_rejects_old_schema(self):
        response = FakeResponse(200, {"response_schema_version": 1, "value": 7})
        self.assertEqual(response_object(response)["value"], 7)
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            response_object(FakeResponse(200, {"response_schema_version": 1}, schema="0"))

    def test_raises_typed_machine_error(self):
        response = FakeResponse(
            400,
            {
                "response_schema_version": 1,
                "code": "oidc_poll_invalid",
                "message": "localized",
                "retryable": False,
            },
            kind="error",
        )
        with self.assertRaises(ManagementResponseError) as raised:
            response_object(response)
        self.assertEqual(raised.exception.code, "oidc_poll_invalid")
        self.assertFalse(raised.exception.retryable)

    def test_accepts_only_204_empty_success(self):
        require_empty_success(FakeResponse(204, None, kind="empty", content=b""))
        with self.assertRaisesRegex(ValueError, "empty"):
            require_empty_success(FakeResponse(200, None, content=b""))


if __name__ == "__main__":
    unittest.main()

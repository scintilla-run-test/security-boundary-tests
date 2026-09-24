import json
import unittest

from deep_tests.security_model import BoundaryViolation, validate_stdio_response


INVOCATION_ID = "release-42:invocation-7"


def wire(result: dict[str, object], **extra: object) -> bytes:
    value: dict[str, object] = {
        "protocol": "stdio-json-v1",
        "invocationId": INVOCATION_ID,
        "result": result,
    }
    value.update(extra)
    return json.dumps(value, separators=(",", ":")).encode() + b"\n"


class StdioJsonBoundaryTests(unittest.TestCase):
    def test_exact_success_response_is_admitted(self) -> None:
        response = validate_stdio_response(
            wire({"status": "ok", "payload": {"answer": 42}}),
            INVOCATION_ID,
        )
        self.assertEqual(response["invocationId"], INVOCATION_ID)

    def test_exact_error_response_is_admitted(self) -> None:
        validate_stdio_response(
            wire(
                {
                    "status": "error",
                    "error": {
                        "code": "dependency.timeout",
                        "message": "upstream timed out",
                        "retryable": True,
                    },
                }
            ),
            INVOCATION_ID,
        )

    def test_wrong_invocation_id_is_rejected(self) -> None:
        body = json.loads(wire({"status": "ok", "payload": None}))
        body["invocationId"] = "other-invocation"
        with self.assertRaises(BoundaryViolation):
            validate_stdio_response(
                json.dumps(body, separators=(",", ":")).encode() + b"\n",
                INVOCATION_ID,
            )

    def test_unknown_top_level_field_is_rejected(self) -> None:
        with self.assertRaises(BoundaryViolation):
            validate_stdio_response(
                wire({"status": "ok", "payload": None}, debug="secret-ish"),
                INVOCATION_ID,
            )

    def test_unknown_result_and_error_fields_are_rejected(self) -> None:
        with self.assertRaises(BoundaryViolation):
            validate_stdio_response(
                wire({"status": "ok", "payload": None, "diagnostic": "no"}),
                INVOCATION_ID,
            )
        with self.assertRaises(BoundaryViolation):
            validate_stdio_response(
                wire(
                    {
                        "status": "error",
                        "error": {
                            "code": "bad.request",
                            "message": "bad",
                            "retryable": False,
                            "stack": "must not cross protocol boundary",
                        },
                    }
                ),
                INVOCATION_ID,
            )

    def test_multiple_lines_trailing_output_and_missing_terminator_are_rejected(self) -> None:
        valid = wire({"status": "ok", "payload": None})
        for candidate in (
            valid + b'{"extra":true}\n',
            valid + b"diagnostic on stdout",
            valid[:-1],
        ):
            with self.subTest(candidate=candidate), self.assertRaises(BoundaryViolation):
                validate_stdio_response(candidate, INVOCATION_ID)

    def test_malformed_non_utf8_nul_and_oversized_output_are_rejected(self) -> None:
        candidates = (
            b"{not-json}\n",
            b'\xff\n',
            b'{"x":"\x00"}\n',
        )
        for candidate in candidates:
            with self.subTest(candidate=candidate), self.assertRaises(BoundaryViolation):
                validate_stdio_response(candidate, INVOCATION_ID)
        with self.assertRaises(BoundaryViolation):
            validate_stdio_response(
                wire({"status": "ok", "payload": "x" * 512}),
                INVOCATION_ID,
                max_output_bytes=128,
            )

    def test_protocol_result_discriminator_and_error_bounds_fail_closed(self) -> None:
        base = json.loads(wire({"status": "ok", "payload": None}))
        base["protocol"] = "stdio-json-v2"
        with self.assertRaises(BoundaryViolation):
            validate_stdio_response(
                json.dumps(base, separators=(",", ":")).encode() + b"\n",
                INVOCATION_ID,
            )

        for result in (
            {"status": "maybe", "payload": None},
            {
                "status": "error",
                "error": {"code": "UpperCase", "message": "bad", "retryable": False},
            },
            {
                "status": "error",
                "error": {"code": "bad.request", "message": "", "retryable": False},
            },
            {
                "status": "error",
                "error": {
                    "code": "bad.request",
                    "message": "x" * 4097,
                    "retryable": False,
                },
            },
            {
                "status": "error",
                "error": {"code": "bad.request", "message": "bad", "retryable": "no"},
            },
        ):
            with self.subTest(result=result), self.assertRaises(BoundaryViolation):
                validate_stdio_response(wire(result), INVOCATION_ID)


if __name__ == "__main__":
    unittest.main()

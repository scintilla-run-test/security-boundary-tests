import unittest

from deep_tests.security_model import BoundaryViolation, normalize_relative_path, validate_outbound_url


class SecurityWave3Tests(unittest.TestCase):
    def test_mixed_windows_and_percent_encoded_parent_segments_fail_closed(self):
        for value in ("..\\secret", "safe\\..\\secret", "%2e%2e%5csecret", "safe/%2e%2e%5csecret"):
            with self.assertRaises(BoundaryViolation):
                normalize_relative_path(value)

    def test_dns_suffix_and_userinfo_authority_confusion_are_rejected(self):
        allowed = {"api.example.test"}
        for value in (
            "https://api.example.test.evil.invalid/v1",
            "https://api.example.test@evil.invalid/v1",
            "//api.example.test/v1",
        ):
            with self.assertRaises(BoundaryViolation):
                validate_outbound_url(value, allowed)


if __name__ == "__main__":
    unittest.main()

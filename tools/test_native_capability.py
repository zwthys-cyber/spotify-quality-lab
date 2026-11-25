import hashlib
import unittest
from unittest.mock import patch

import native_capability as native


class NativeCapabilityTests(unittest.TestCase):
    def fixture(self):
        return b'\xAA' * 64 + native.ORIGINAL_PROLOGUE + b'\xBB' * 64

    def test_exact_eight_bytes_change_without_moving_following_code(self):
        original = self.fixture()
        with patch.object(native, 'EXPECTED_SHA256', hashlib.sha256(original).hexdigest()), \
                patch.object(native, 'PATCH_OFFSET', 64):
            result = native.patch_native_capability(original)
        self.assertEqual(len(result), len(original))
        self.assertEqual(result[:64], original[:64])
        self.assertEqual(result[64:72], bytes.fromhex('40008052c0035fd6'))
        self.assertEqual(result[72:], original[72:])

    def test_rejects_different_build(self):
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            native.patch_native_capability(self.fixture())

    def test_rejects_code_mismatch_even_with_matching_digest(self):
        original = b'\0' * 128
        with patch.object(native, 'EXPECTED_SHA256', hashlib.sha256(original).hexdigest()), \
                patch.object(native, 'PATCH_OFFSET', 64):
            with self.assertRaisesRegex(ValueError, 'original code mismatch'):
                native.patch_native_capability(original)


if __name__ == '__main__':
    unittest.main()

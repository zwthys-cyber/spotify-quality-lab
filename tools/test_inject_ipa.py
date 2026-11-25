import struct
import unittest

from inject_ipa import inject


class InjectionTests(unittest.TestCase):
    path = '@executable_path/Frameworks/QualityLab.dylib'

    def binary(self, first_section=512, encrypted=False):
        commands_size = 152 + (24 if encrypted else 0)
        header = struct.pack('<IIIIIIII', 0xFEEDFACF, 0x100000C, 0, 2,
                             2 if encrypted else 1, commands_size, 0, 0)
        segment = struct.pack('<II16sQQQQiiII', 0x19, 152, b'__TEXT',
                              0x100000000, 1024, 0, 1024, 7, 5, 1, 0)
        section = struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT',
                              0x100000000 + first_section, 64, first_section,
                              2, 0, 0, 0, 0, 0, 0)
        commands = segment + section
        if encrypted:
            commands += struct.pack('<IIIIII', 0x2C, 24, 512, 64, 1, 0)
        return (header + commands).ljust(first_section, b'\0') + b'\xA5' * 64

    def test_only_header_padding_and_command_counts_change(self):
        original = self.binary()
        changed = inject(original, self.path)
        self.assertEqual(len(original), len(changed))
        self.assertEqual(changed[512:], original[512:])
        self.assertEqual(changed[32:184], original[32:184])
        self.assertEqual(struct.unpack_from('<I', changed, 16)[0], 2)
        command, size, offset = struct.unpack_from('<III', changed, 184)
        self.assertEqual(command, 0xC)
        self.assertEqual(size % 8, 0)
        self.assertEqual(changed[184 + offset:].split(b'\0')[0].decode(), self.path)

    def test_rejects_duplicate_injection(self):
        with self.assertRaisesRegex(ValueError, 'already injected'):
            inject(inject(self.binary(), self.path), self.path)

    def test_rejects_insufficient_padding(self):
        with self.assertRaisesRegex(ValueError, 'padding'):
            inject(self.binary(first_section=184), self.path)

    def test_rejects_encrypted_input(self):
        with self.assertRaisesRegex(ValueError, 'encrypted'):
            inject(self.binary(encrypted=True), self.path)

    def test_rejects_nonzero_padding(self):
        binary = bytearray(self.binary())
        binary[190] = 1
        with self.assertRaisesRegex(ValueError, 'padding'):
            inject(binary, self.path)


if __name__ == '__main__':
    unittest.main()

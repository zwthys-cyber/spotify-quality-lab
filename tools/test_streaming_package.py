import hashlib
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

from inject_ipa import package_ipa
from test_inject_ipa import InjectionTests


class StreamingPackageTests(unittest.TestCase):
    def test_preserves_sections_resources_and_input_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original, plugin, output = root / 'input.ipa', root / 'plugin.dylib', root / 'output.ipa'
            main = InjectionTests().binary() + b'large-resource' * 100000
            library = struct.pack('<IIIIIIII', 0xFEEDFACF, 0x100000C, 0, 6, 0, 0, 0, 0)
            plugin.write_bytes(library)
            info = {'CFBundleExecutable': 'Spotify', 'CFBundleShortVersionString': '9.2.2'}
            with zipfile.ZipFile(original, 'w') as archive:
                archive.writestr('Payload/Spotify.app/Info.plist', plistlib.dumps(info))
                archive.writestr('Payload/Spotify.app/Spotify', main)
                archive.writestr('Payload/Spotify.app/resource.bin', b'preserved resource')
                archive.writestr('Payload/Spotify.app/_CodeSignature/CodeResources', b'old signature')
            before = hashlib.sha256(original.read_bytes()).hexdigest()
            package_ipa(original, plugin, output)
            with zipfile.ZipFile(output) as archive:
                patched = archive.read('Payload/Spotify.app/Spotify')
                self.assertEqual(len(patched), len(main))
                self.assertEqual(patched[512:], main[512:])
                self.assertEqual(struct.unpack_from('<I', patched, 16)[0], 2)
                self.assertEqual(archive.read('Payload/Spotify.app/resource.bin'), b'preserved resource')
                self.assertEqual(archive.read('Payload/Spotify.app/Frameworks/QualityLab.dylib'), library)
                self.assertNotIn('Payload/Spotify.app/_CodeSignature/CodeResources', archive.namelist())
            self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), before)
            self.assertFalse(list(root.glob('*.partial')))

    def test_failed_native_digest_does_not_publish_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original, plugin, output = root / 'input.ipa', root / 'plugin.dylib', root / 'output.ipa'
            plugin.write_bytes(struct.pack('<IIIIIIII', 0xFEEDFACF, 0x100000C, 0, 6, 0, 0, 0, 0))
            with zipfile.ZipFile(original, 'w') as archive:
                archive.writestr('Payload/Spotify.app/Info.plist', plistlib.dumps({'CFBundleExecutable':'Spotify','CFBundleShortVersionString':'9.2.2'}))
                archive.writestr('Payload/Spotify.app/Spotify', InjectionTests().binary())
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                package_ipa(original, plugin, output, native_capability_2=True)
            self.assertFalse(output.exists())
            self.assertFalse(list(root.glob('*.partial')))


if __name__ == '__main__':
    unittest.main()

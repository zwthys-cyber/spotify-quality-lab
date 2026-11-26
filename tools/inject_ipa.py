"""Package a built dylib into this decrypted IPA; does not compile or run it.

The output requires signing on the user's device. Refuses binaries without
enough unused load-command padding; never shifts executable sections.
"""
import argparse
import copy
import hashlib
import os
import shutil
import tempfile
from pathlib import Path
import plistlib
import struct
import zipfile
from native_capability import EXPECTED_SHA256, PATCH_OFFSET, ORIGINAL_PROLOGUE, PATCH_BYTES


def inject(binary, library_path):
    result = bytearray(binary)
    if struct.unpack_from('<I', result)[0] != 0xFEEDFACF:
        raise ValueError('Expected a thin 64-bit little-endian Mach-O')
    if struct.unpack_from('<I', result, 4)[0] != 0x100000C:
        raise ValueError('Expected arm64')
    count, command_bytes = struct.unpack_from('<II', result, 16)
    end = 32 + command_bytes
    if end > len(result):
        raise ValueError('Truncated load commands')
    first_section = len(result)
    cursor = 32
    for _ in range(count):
        command, size = struct.unpack_from('<II', result, cursor)
        if size < 8 or cursor + size > end:
            raise ValueError('Invalid load command')
        if command == 0x2C and struct.unpack_from('<I', result, cursor + 16)[0]:
            raise ValueError('Executable is encrypted')
        if command in (0xC, 0x18, 0x80000018):
            name_offset = struct.unpack_from('<I', result, cursor + 8)[0]
            name = bytes(result[cursor + name_offset:cursor + size]).split(b'\0')[0]
            if name.decode() == library_path:
                raise ValueError('Library is already injected')
        if command == 0x19:
            sections = struct.unpack_from('<I', result, cursor + 64)[0]
            if 72 + 80 * sections > size:
                raise ValueError('Invalid section table')
            for index in range(sections):
                section = cursor + 72 + index * 80
                length = struct.unpack_from('<Q', result, section + 40)[0]
                offset = struct.unpack_from('<I', result, section + 48)[0]
                if length and offset:
                    first_section = min(first_section, offset)
        cursor += size
    if cursor != end:
        raise ValueError('Inconsistent command size')
    name = library_path.encode() + b'\0'
    size = (24 + len(name) + 7) & ~7
    if end + size > first_section or any(result[end:end + size]):
        raise ValueError('Insufficient empty header padding')
    command = struct.pack('<IIIIII', 0xC, size, 24, 0, 0x10000, 0x10000) + name
    result[end:end + size] = command.ljust(size, b'\0')
    struct.pack_into('<II', result, 16, count + 1, command_bytes + size)
    return bytes(result)


def package_ipa(ipa, dylib, destination, native_capability_2=False):
    ipa, dylib, destination = Path(ipa), Path(dylib), Path(destination)
    if destination.resolve() == ipa.resolve() or destination.exists():
        raise ValueError('Output must be a new file')
    library = dylib.read_bytes()
    if len(library) < 32 or struct.unpack_from('<III', library) != (0xFEEDFACF, 0x100000C, 0):
        raise ValueError('Expected thin arm64 dylib')
    if struct.unpack_from('<I', library, 12)[0] != 6:
        raise ValueError('Expected MH_DYLIB')
    with tempfile.TemporaryDirectory(prefix='qualitylab-package-') as temporary, zipfile.ZipFile(ipa) as source:
        infos = [n for n in source.namelist() if n.endswith('.app/Info.plist') and n.count('/') == 2]
        if len(infos) != 1:
            raise ValueError('Expected one main app')
        info = plistlib.loads(source.read(infos[0]))
        if info.get('CFBundleExecutable') != 'Spotify' or info.get('CFBundleShortVersionString') != '9.2.2':
            raise ValueError('Only Spotify 9.2.2 is supported')
        app = infos[0].rsplit('/', 1)[0]
        executable = app + '/Spotify'
        target = app + '/Frameworks/QualityLab.dylib'
        if target in source.namelist():
            raise ValueError('Target library already exists')
        executable_file = Path(temporary) / 'Spotify'
        digest = hashlib.sha256()
        with source.open(executable) as incoming, executable_file.open('wb') as outgoing:
            while block := incoming.read(1024 * 1024):
                digest.update(block)
                outgoing.write(block)
        with executable_file.open('r+b') as stream:
            if native_capability_2:
                if digest.hexdigest() != EXPECTED_SHA256:
                    raise ValueError('Native capability patch: executable digest mismatch')
                stream.seek(PATCH_OFFSET)
                if stream.read(len(ORIGINAL_PROLOGUE)) != ORIGINAL_PROLOGUE:
                    raise ValueError('Native capability patch: original code mismatch')
                stream.seek(PATCH_OFFSET)
                stream.write(PATCH_BYTES)
                info['QualityLabNativeCapability'] = 2
            # Only the header and its existing padding are needed. Keep the
            # remaining 250 MB on disk instead of allocating several copies.
            stream.seek(0)
            prefix = stream.read(1024 * 1024)
            patched_prefix = inject(prefix, '@executable_path/Frameworks/QualityLab.dylib')
            stream.seek(0)
            stream.write(patched_prefix)
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=destination.name + '.', suffix='.partial', delete=False) as handle:
            partial = Path(handle.name)
        try:
            with zipfile.ZipFile(partial, 'w', zipfile.ZIP_DEFLATED, compresslevel=1) as output:
                for original_entry in source.infolist():
                    if original_entry.filename.startswith(app + '/_CodeSignature/'):
                        continue
                    entry = copy.copy(original_entry)
                    entry._compresslevel = 1
                    if entry.filename == infos[0] and native_capability_2:
                        output.writestr(entry, plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
                        continue
                    incoming = executable_file.open('rb') if entry.filename == executable else source.open(original_entry)
                    with incoming, output.open(entry, 'w') as outgoing:
                        shutil.copyfileobj(incoming, outgoing, length=1024 * 1024)
                entry = zipfile.ZipInfo(target)
                entry.external_attr = 0o100755 << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry._compresslevel = 1
                output.writestr(entry, library)
            if destination.exists():
                raise ValueError('Output appeared while packaging; refusing overwrite')
            os.replace(partial, destination)
        finally:
            partial.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('dylib', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--native-capability-2', action='store_true',
                        help='Patch the exact original 9.2.2 native capability getter; always active until original IPA is restored')
    args = parser.parse_args()
    package_ipa(args.ipa, args.dylib, args.output, args.native_capability_2)
    print(f'Packaged {args.output}; must be re-signed before installation')


if __name__ == '__main__':
    main()

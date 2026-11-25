"""Package a built dylib into this decrypted IPA; does not compile or run it.

The output requires signing on the user's device. Refuses binaries without
enough unused load-command padding; never shifts executable sections.
"""
import argparse
from pathlib import Path
import plistlib
import struct
import zipfile
from native_capability import patch_native_capability


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('dylib', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--native-capability-2', action='store_true',
                        help='Patch the exact original 9.2.2 native capability getter; always active until original IPA is restored')
    args = parser.parse_args()
    if args.output.resolve() == args.ipa.resolve() or args.output.exists():
        raise ValueError('Output must be a new file')
    library = args.dylib.read_bytes()
    if len(library) < 32 or struct.unpack_from('<III', library) != (0xFEEDFACF, 0x100000C, 0):
        raise ValueError('Expected thin arm64 dylib')
    if struct.unpack_from('<I', library, 12)[0] != 6:
        raise ValueError('Expected MH_DYLIB')
    with zipfile.ZipFile(args.ipa) as source:
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
        original = source.read(executable)
        if args.native_capability_2:
            original = patch_native_capability(original)
            info['QualityLabNativeCapability'] = 2
        patched = inject(original, '@executable_path/Frameworks/QualityLab.dylib')
        with zipfile.ZipFile(args.output, 'x', zipfile.ZIP_DEFLATED, compresslevel=6) as output:
            for entry in source.infolist():
                if entry.filename.startswith(app + '/_CodeSignature/'):
                    continue
                data = source.read(entry)
                if entry.filename == executable:
                    data = patched
                elif entry.filename == infos[0] and args.native_capability_2:
                    data = plistlib.dumps(info, fmt=plistlib.FMT_BINARY)
                output.writestr(entry, data)
            entry = zipfile.ZipInfo(target)
            entry.external_attr = 0o100755 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            output.writestr(entry, library)
    print(f'Packaged {args.output}; must be re-signed before installation')


if __name__ == '__main__':
    main()

"""Exact-build static experiment: change the native client capability getter.

This changes a local capability value, not the requested preference or server
account entitlement. Input digest and original code must both match.
"""
import hashlib
import struct

EXPECTED_SHA256 = '5c120fe41e2f0c40e34ccd340305fcd903bd9cb19aa41af6f4548c81117242c9'
PATCH_OFFSET = 0x9307988
ORIGINAL_PROLOGUE = bytes.fromhex('ff0301d1f44f02a9fd7b03a9fdc30091ff1300b901f000f0')
# mov w0, #2; ret. The original getter validates capability values 0, 1, 2.
PATCH_BYTES = struct.pack('<II', 0x52800040, 0xD65F03C0)


def patch_native_capability(binary):
    if hashlib.sha256(binary).hexdigest() != EXPECTED_SHA256:
        raise ValueError('Native capability patch: executable digest mismatch')
    if binary[PATCH_OFFSET:PATCH_OFFSET + len(ORIGINAL_PROLOGUE)] != ORIGINAL_PROLOGUE:
        raise ValueError('Native capability patch: original code mismatch')
    result = bytearray(binary)
    result[PATCH_OFFSET:PATCH_OFFSET + len(PATCH_BYTES)] = PATCH_BYTES
    return bytes(result)

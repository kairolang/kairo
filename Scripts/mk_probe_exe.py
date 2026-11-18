#!/usr/bin/env python3
"""Write a minimal PE32+ console program that exits with code 42.

    mk_probe_exe.py <out.exe>

Used by Tests/lit.cfg.py to check that Wine can start an executable at all,
without needing a compiler or a Windows sysroot. The image has no imports:
its entry point is `mov eax, 42; ret`.
"""
import struct
import sys


def build():
    code = b"\xb8\x2a\x00\x00\x00\xc3"
    file_align, sect_align = 0x200, 0x1000
    hdr_size = 0x200
    dos = b"MZ" + b"\0" * 58 + struct.pack("<I", 0x40)
    pe = b"PE\0\0" + struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, 0xF0, 0x0022)
    opt = struct.pack("<HBBIIIIIQIIHHHHHHIIIIHHQQQQII",
                      0x20B, 14, 0, file_align, 0, 0, 0x1000, 0x1000,
                      0x140000000, sect_align, file_align,
                      6, 0, 0, 0, 6, 0, 0, 0x2000, hdr_size, 0, 3, 0x8160,
                      0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    opt += b"\0" * (16 * 8)
    sect = b".text\0\0\0" + struct.pack("<IIIIIIHHI", len(code), 0x1000,
                                        file_align, hdr_size, 0, 0, 0, 0,
                                        0x60000020)
    hdr = dos + pe + opt + sect
    hdr += b"\0" * (hdr_size - len(hdr))
    return hdr + code + b"\0" * (file_align - len(code))


if __name__ == "__main__":
    open(sys.argv[1], "wb").write(build())

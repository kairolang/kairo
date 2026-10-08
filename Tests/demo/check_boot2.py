import struct, sys
d = open(sys.argv[1], "rb").read()
assert len(d) == 256, f"size is {len(d)}, expected 256"
crc = 0xFFFFFFFF
for b in d[:252]:
    crc ^= b << 24
    for _ in range(8):
        crc = ((crc << 1) ^ 0x04C11DB7) if crc & 0x80000000 else (crc << 1)
        crc &= 0xFFFFFFFF
stored = struct.unpack("<I", d[252:])[0]
if crc != stored:
    sys.exit(f"BAD boot2: computed {crc:#010x}, stored {stored:#010x}")
print("boot2 ok")
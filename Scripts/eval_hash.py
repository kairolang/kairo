#!/usr/bin/env python3
"""The 32-bit hash of a spelling, as Compiler/Support/EvalHash.k computes it.

An FNV-1a variant: the byte's index is xored in after each byte, the length
times the golden-ratio constant is mixed in at the end, RESERVED_LOW is added,
and the 64-bit result is folded to 32 bits. The empty string hashes to the
fold of all ones.

Scripts/gen_diag.py takes every DiagID's value from here, and
Scripts/check_token_hashes.py holds EvalHash.k's constants and the TokenKind
values to it.
"""

M64 = (1 << 64) - 1
FNV_OFFSET_BASIS = 0x14650FB0739D0383
FNV_PRIME = 0x00000100000001b3
GOLDEN_RATIO_MIX = 0x9e3779b97f4a7c15
RESERVED_LOW = 0x00000000000000FF


def fold_hash(h):
    return ((h >> 32) ^ h) & 0xFFFFFFFF


def compute_hash(text):
    """EvalHash.k's `compute_hash` of the text's UTF-8 bytes."""
    data = text.encode("utf-8")
    if not data:
        return fold_hash(M64)
    h = FNV_OFFSET_BASIS
    for i, c in enumerate(data):
        h = ((h ^ c) * FNV_PRIME) & M64
        h ^= i
    return fold_hash(((h ^ ((len(data) * GOLDEN_RATIO_MIX) & M64)) + RESERVED_LOW) & M64)


if __name__ == "__main__":
    import sys

    for word in sys.argv[1:]:
        print(compute_hash(word), word)

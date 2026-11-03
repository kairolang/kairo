/// --- The Kairo Project ----------------------- Lib/builtin/base/hash.k --- ///
///
///   \brief The Hash lang item: what a `{K: V}` / `{T}` key conforms to, and
///          its conformances for the primitives, pointers and `string`.
///
///   \detail
///     `interface Hash` asks for a hash and an equality consistent with it
///     (a == b implies a.hash() == b.hash()). A key type conforms the way
///     any type conforms to any interface (interfaces.md): its own
///     members, an `extend X impl Hash`, or structurally.
///
///     What conforms with no Kairo code (ConformanceChecking::
///     _native_implementation, CODEGEN.md 7b.4):
///       - `op ==` on a builtin, a pointer and an imported C++ type is the
///         type's own `==` (the witness spells `self == other`; for a C++
///         type C++ picks the member or free operator, and checks it);
///       - `hash` on an imported C++ type is `std::hash<X>{}(v)`: a C++ type
///         that keys a `std::unordered_map` keys a `{K: V}` as is;
///       - `hash` on a pointer is its address (the table mixes it).
///     The primitives' `hash` is below (`extend i32 impl Hash`): a builtin
///     has no members, so its conformance is an extension here, in the
///     interface's file (extends.md, "Same-File Restriction").
///
///     The functions (all deterministic: no per-process seed, so a map's
///     layout -- and its iteration order, which is insertion order anyway --
///     is the same on every run):
///       - integers, chars, bool: `mix64`, rapidhash's / wyhash's folded
///         multiply: the 128-bit product of (x ^ S0) and S1, its two halves
///         xored. One `mul` and two `xor`s on a 64-bit target; a full-
///         avalanche mix, so a weak key distribution (multiples of 8,
///         sequential ids) spreads over every bit.
///       - bytes (`string`): `hash_bytes`, rapidhash (v1, Nicolas De
///         Carli, MIT; wyhash's successor): 16-byte and shorter inputs in
///         one folded multiply after two overlapping reads, longer ones in
///         three 16-byte lanes per 48 bytes. Reads are unaligned 4/8-byte
///         loads in the target's byte order, so a hash is stable per
///         target, not across targets of different endianness.
///       - floats: the bit pattern's, after +0.0 / -0.0 are made one (they
///         compare equal). A NaN compares unequal to everything, itself
///         included, so a NaN key can be inserted but never found again;
///         do not key a map by a float that may be NaN.
///     Where usize is 32 bits the 64-bit result is folded (hi ^ lo).
///
///     Not provided: i256..i512 / u256..u512 and the f8 / f16 / f128-and-up
///     floats (no key use yet; extend them here when one appears).
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import base::intrinsics::*
import string::*

/// A key: a hash and an equality consistent with it. `other` is `const`
/// (by reference), so comparing two strings copies neither.
pub interface Hash {
    fn hash(const self) -> usize
    fn op ==(const self, const other: Self) -> bool
}

// --- the mixers --------------------------------------------------------------

/// rapidhash's default secrets.
eval HASH_S0: u64 = 0x2d358dccaa6c78a5u64
eval HASH_S1: u64 = 0x8bb84b93962eacc9u64
eval HASH_S2: u64 = 0x4b33a62ed433d4a3u64

/// The 128-bit product of a and b, its high and low halves xored: the
/// folded multiply every mix below is made of. One `mul` where the target
/// has a 64x64->128 multiply; four 32x32 products elsewhere.
pub inline fn fold_mul(a: u64, b: u64) -> u64 {
    eval if defined!(__SIZEOF_INT128__) {
        var r = (a as u128) * (b as u128)
        return (r as u64) ^ ((r >> 64) as u64)
    } else {
        var lo: u64 = 0
        var hi: u64 = 0
        mul_wide(a, b, &lo, &hi)
        return lo ^ hi
    }
}

/// a * b as two 64-bit halves, for targets with no 128-bit integer.
inline fn mul_wide(a: u64, b: u64, lo: *u64, hi: *u64) {
    var ha = a >> 32
    var hb = b >> 32
    var la = a & 0xffffffffu64
    var lb = b & 0xffffffffu64
    var rh = ha * hb
    var rm0 = ha * lb
    var rm1 = hb * la
    var rl = la * lb
    var t = rl + (rm0 << 32)
    var c: u64 = (if t < rl => 1u64 else => 0u64)
    var l = t + (rm1 << 32)
    c += (if l < t => 1u64 else => 0u64)
    (*lo) = l
    (*hi) = rh + (rm0 >> 32) + (rm1 >> 32) + c
}

/// Both halves of a * b, written back: rapidhash's `rapid_mum`.
inline fn mum(a: *u64, b: *u64) {
    eval if defined!(__SIZEOF_INT128__) {
        var r = ((*a) as u128) * ((*b) as u128)
        (*a) = r as u64
        (*b) = (r >> 64) as u64
    } else {
        var lo: u64 = 0
        var hi: u64 = 0
        mul_wide(*a, *b, &lo, &hi)
        (*a) = lo
        (*b) = hi
    }
}

/// A 64-bit hash as a usize: itself on a 64-bit target, folded on a 32-bit one.
pub inline fn to_usize(h: u64) -> usize {
    if sizeof usize >= 8 { return h as usize }
    return (h ^ (h >> 32)) as usize
}

/// The integer mix: a full-avalanche hash of 64 bits.
pub inline fn mix64(x: u64) -> u64 { return fold_mul(x ^ HASH_S0, HASH_S1) }

/// 8 bytes at p, unaligned, in the target's byte order.
inline fn read64(p: unsafe *const u8) -> u64 {
    var v: u64 = 0
    unsafe { __builtin_copy(&v as unsafe *u8, p, 8) }
    return v
}

/// 4 bytes at p, unaligned, widened.
inline fn read32(p: unsafe *const u8) -> u64 {
    var v: u32 = 0
    unsafe { __builtin_copy(&v as unsafe *u8, p, 4) }
    return v
}

/// rapidhash (v1) of the `len` bytes at p.
pub inline fn hash_bytes(p: unsafe *const u8, len: usize) -> u64 { return hash_bytes_seeded(p, len, 0) }

/// rapidhash (v1) of the `len` bytes at p, seeded with `seed`. (No default
/// argument: a defaulted call goes through an out-of-line thunk.)
pub fn hash_bytes_seeded(p: unsafe *const u8, len: usize, seed: u64) -> u64 {
    var n = len as u64
    var s = seed ^ fold_mul(seed ^ HASH_S0, HASH_S1) ^ n
    var a: u64 = 0
    var b: u64 = 0
    unsafe {
        if len <= 16 {
            if len >= 4 {
                var unsafe *last = p + (len - 4)
                a = (read32(p) << 32) | read32(last)
                var delta = (len & 24) >> (len >> 3)
                b = (read32(p + delta) << 32) | read32(last - delta)
            } else if len > 0 {
                a = ((p[0] as u64) << 56) | ((p[len >> 1] as u64) << 32) | (p[len - 1] as u64)
            }
        } else {
            var unsafe *q = p
            var i = len
            if i > 48 {
                var s1 = s
                var s2 = s
                while i >= 48 {
                    s  = fold_mul(read64(q) ^ HASH_S0, read64(q + 8) ^ s)
                    s1 = fold_mul(read64(q + 16) ^ HASH_S1, read64(q + 24) ^ s1)
                    s2 = fold_mul(read64(q + 32) ^ HASH_S2, read64(q + 40) ^ s2)
                    q = q + 48
                    i -= 48
                }
                s ^= s1 ^ s2
            }
            if i > 16 {
                s = fold_mul(read64(q) ^ HASH_S2, read64(q + 8) ^ s ^ HASH_S1)
                if i > 32 { s = fold_mul(read64(q + 16) ^ HASH_S2, read64(q + 24) ^ s) }
            }
            // The last 16 bytes of the input, overlapping what the lanes read.
            a = read64(p + (len - 16))
            b = read64(p + (len - 8))
        }
    }
    a ^= HASH_S1
    b ^= s
    mum(&a, &b)
    return fold_mul(a ^ HASH_S0 ^ n, b ^ HASH_S1)
}

// --- the primitives ------------------------------------------------------------
// `op ==` is each type's own (ConformanceChecking::_native_implementation).

extend bool impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(if self => 1u64 else => 0u64)) }
extend u8   impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(self)) }
extend u16  impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(self)) }
extend u32  impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(self)) }
extend u64  impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(self)) }
extend i8   impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(self as u64)) }
extend i16  impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(self as u64)) }
extend i32  impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(self as u64)) }
extend i64  impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(self as u64)) }
extend usize impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(self as u64)) }
extend isize impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(self as u64)) }
extend char impl Hash { pub inline fn hash(const self) -> usize = to_usize(mix64(self as u64)) }

extend u128 impl Hash {
    pub inline fn hash(const self) -> usize = to_usize(fold_mul((self as u64) ^ HASH_S0, ((self >> 64) as u64) ^ HASH_S1))
}
extend i128 impl Hash {
    pub inline fn hash(const self) -> usize = to_usize(fold_mul((self as u64) ^ HASH_S0, (((self as u128) >> 64) as u64) ^ HASH_S1))
}

extend f32 impl Hash {
    /// -0.0 == +0.0, so both hash as +0.0's bits (0).
    pub inline fn hash(const self) -> usize {
        if self == 0.0f32 { return to_usize(mix64(0)) }
        return to_usize(mix64(__builtin_bitcast<u32>(self)))
    }
}
extend f64 impl Hash {
    pub inline fn hash(const self) -> usize {
        if self == 0.0 { return to_usize(mix64(0)) }
        return to_usize(mix64(__builtin_bitcast<u64>(self)))
    }
}

// --- string ------------------------------------------------------------------
// `op ==` is string's own, derived from string.k's `op <=>` (length first,
// then one memcmp); `hash` stays here, beside the other conformances.

extend string impl Hash {
    pub inline fn hash(const self) -> usize {
        unsafe { return to_usize(hash_bytes(self.as_ptr() as unsafe *const u8, self.length())) }
    }
}

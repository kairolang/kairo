/// builtin/base/hash.k
///
/// A folded-multiply hasher. Hashes are the same on every target that takes
/// the same `mum` path with the same seed: bytes are assembled little-endian
/// everywhere. The wide path (one 64x64->128 multiply) and the narrow path
/// (two 32x32->64 multiplies) do not agree with each other.
///
/// Flood resistance rests on the seed being secret. `process_seed` draws it
/// from address-space layout, which is constant on targets with no ASLR
/// (wasm, freestanding): those need a real entropy source behind it.

import base::cmp::*
import base::intrinsics::*
import containers::slice::*

// Odd in both 32-bit halves, so neither narrow-path multiplier is even.
priv eval K0: u64 = 0x9e3779b97f4a7c15u64
priv eval K1: u64 = 0xbf58476d1ce4e5b9u64
priv eval K2: u64 = 0x94d049bb133111ebu64

priv eval PINNED_SEED: u64 = 0x243f6a8885a308d3u64

// The `mum` path, by architecture rather than pointer width: x32 and arm64_32
// have 32-bit pointers and a native 64x64->128 multiply. `__SIZEOF_INT128__`
// cannot decide it, since `u128` exists on 32-bit targets too.
// `-DKAIRO_HASH_NARROW` takes the narrow path anywhere, which is how a
// 64-bit host tests it.
// COMPILER-WORKAROUND(eval-if-decl-twice): one declaration, not one per
// branch of an `eval if`: an importer of an importer sees both branches'.
priv eval WIDE_MUM: bool = !defined!(KAIRO_HASH_NARROW) && (defined!(__x86_64__) || defined!(__aarch64__) || defined!(__LP64__) || defined!(_WIN64) || defined!(__mips64))

/// The fold every step is made of.
///
/// Wide: the 128-bit product of `a` and `b`, high half xor low half. One
/// `mul` on x86-64, `mul` + `umulh` on AArch64.
///
/// Narrow: the two cross products of the 32-bit halves, the second rotated
/// by 32 so each half of the result holds the high word of one product. A
/// 32x32 product moves a bit at most 32 places up, so one narrow fold mixes
/// less than a wide one; `finish` runs two of them to make up for it.
priv inline fn mum(a: u64, b: u64) -> u64 {
    eval if WIDE_MUM {
        var r = (a as u128) * (b as u128)
        return (r as u64) ^ ((r >> 64) as u64)
    } else {
        var x = (a & 0xffffffffu64) * (b >> 32)
        var y = (a >> 32) * (b & 0xffffffffu64)
        return x ^ ((y << 32) | (y >> 32))
    }
}

/// 8 bytes at `p`, any alignment, little-endian.
priv inline fn read64(p: unsafe *const u8) -> u64 {
    var v: u64 = 0
    unsafe {
        __builtin_copy(&v as unsafe *u8, p, 8)
    }

    eval if defined!(__BIG_ENDIAN__) {
        return __builtin_bswap(v)
    } else {
        return v
    }
}

/// 4 bytes at `p`, any alignment, little-endian, zero-extended.
priv inline fn read32(p: unsafe *const u8) -> u64 {
    var v: u32 = 0
    unsafe {
        __builtin_copy(&v as unsafe *u8, p, 4)
    }

    eval if defined!(__BIG_ENDIAN__) {
        return __builtin_bswap(v) as u64
    } else {
        return v
    }
}

/// The state after absorbing `n > 16` bytes at `p`.
///
/// Two lanes, 16 bytes each per step, so two multiplies are in flight at
/// once; then one 16-byte step if more than 16 bytes are left, then the last
/// 16 bytes of the input, which overlap whatever the steps already took.
/// Each multiply has a secret on both sides (a lane, or the seed), so no
/// input word can zero an operand for every seed.
@no_inline priv fn write_long(state: u64, seed: u64, p: unsafe *const u8, n: usize) -> u64 {
    var        k   = seed ^ K1
    var        s0  = state
    var        s1  = seed ^ K2
    var unsafe *q  = p
    var        rem = n
    while rem > 32 {
        unsafe {
            s0 = mum(read64(q) ^ s0, read64(q + 8) ^ k)
            s1 = mum(read64(q + 16) ^ s1, read64(q + 24) ^ k)
            q  = q + 32
        }

        rem -= 32
    }

    if rem > 16 {
        unsafe {
            s0 = mum(read64(q) ^ s0, read64(q + 8) ^ k)
        }
    }

    var a: u64 = 0
    var b: u64 = 0
    unsafe {
        a = read64(p + (n - 16))
        b = read64(p + (n - 8))
    }

    return mum(a ^ s0, b ^ s1) ^ (n as u64)
}

/// Absorbs `n` bytes at `p` into `state`. `p` is not read when `n` is 0.
///
/// Up to 16 bytes take one fold: two words (two overlapping 8-byte reads for
/// 8..16, two 4-byte reads for 4..7, the first / middle / last byte for 1..3,
/// zeros for 0), the length mixed in after it.
@hot_path priv inline fn write_bytes(state: u64, seed: u64, p: unsafe *const u8, n: usize) -> u64 {
    if n > 16 {
        return write_long(state, seed, p, n)
    }

    var a: u64 = 0
    var b: u64 = 0
    if n >= 8 {
        a = read64(p)
        unsafe {
            b = read64(p + (n - 8))
        }
    } else if n >= 4 {
        a = read32(p)
        unsafe {
            b = read32(p + (n - 4))
        }
    } else if n > 0 {
        unsafe {
            a = ((p[0] as u64) << 16) | ((p[n >> 1] as u64) << 8) | (p[n - 1] as u64)
        }
    }

    return mum(a ^ state, b ^ seed ^ K1) ^ (n as u64)
}

/// Seeded by the container; types only feed bytes into it.
///
/// Every member is `inline`: a non-inline member of another module is an
/// out-of-line call at -O2, and an integer key must hash with no call.
pub class Hasher {
    priv var state: u64
    priv var seed:  u64

    pub inline fn Hasher(self, seed: u64) {
        self.state = seed
        self.seed  = seed
    }

    @hot_path pub inline fn write(self, const b: [const u8;]) { // mixes the length in, so ("ab","c") != ("a","bc")
        self.state = write_bytes(self.state, self.seed, b.first_(), b.count_())
    }

    /// One fold: no loop, no call, no branch.
    @hot_path pub inline fn write_u64(self, v: u64) {
        self.state = mum(self.state ^ v, K0)
    }

    @hot_path pub inline fn write_usize(self, v: usize) {
        self.write_u64(v as u64)
    }

    pub inline fn finish(const self) -> u64 {
        eval if WIDE_MUM {
            return mum(self.state, self.seed ^ K1)
        } else {
            // Constant multipliers: a seed whose half cancels a half of K1
            // would otherwise multiply half the state by zero.
            return mum(mum(self.state, K1) ^ self.seed, K2)
        }
    }

    /// Absorbs `n` bytes at `p`, as `write` does a slice of them. For the
    /// library's own byte owners, which hold a pointer and a count.
    ///
    /// \safety `p` must be valid for reads of `n` bytes; it is not read when
    /// `n` is 0.
    @hot_path prot inline fn write_raw_(self, p: unsafe *const u8, n: usize) {
        self.state = write_bytes(self.state, self.seed, p, n)
    }
}

pub interface Hash derives Eq {
    fn hash(const self, @inout h: Hasher)
}

// 0 until the first call. Racing first calls store the same value: it
// depends only on the addresses of two statics, so every thread derives one
// seed and a table may read it again at each lookup.
priv static process_seed_cache:  u64 = 0
priv static process_seed_anchor: u64 = 1

/// The process-wide seed a table starts from; never 0.
///
/// Defining `KAIRO_HASH_SEED` pins it to a fixed constant, so hashes and
/// table layouts repeat from run to run; the define's value is not read,
/// since the branch `eval if defined!(X)` discards still expands `X!`.
/// Otherwise it is derived once from the addresses of two statics, which
/// differ from run to run where the loader randomizes addresses and are no
/// entropy at all where the address space is fixed.
prot fn process_seed() -> u64 {
    eval if defined!(KAIRO_HASH_SEED) {
        return PINNED_SEED
    } else {
        if process_seed_cache == 0 {
            var a: usize = 0
            var b: usize = 0
            unsafe {
                a = (&process_seed_cache as unsafe *u64) as usize
                b = (&process_seed_anchor as unsafe *u64) as usize
            }

            var s = mum(mum((a as u64) ^ K0, K1) ^ (b as u64), K2)
            if s == 0 {
                s = K0
            }

            process_seed_cache = s
        }

        return process_seed_cache
    }
}

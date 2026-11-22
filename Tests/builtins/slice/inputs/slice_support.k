// Support for the slice tests: a seeded generator, raw storage, checks, the
// element types the sorts are run on, and the pattern driver. Not a test.

import std::io
ffi "c" import "stdlib.h"
ffi "c++" import "rt/global_alloc.h"

/// xorshift64*.
pub struct Rng {
    pub var s: u64
}

pub fn rng_make(seed: u64) -> Rng {
    return Rng { s: (if seed == 0 => 0x9E3779B97F4A7C15u64 else => seed) }
}

pub inline fn rng_next(r: *Rng) -> u64 {
    var x = r->s
    x ^= x >> 12
    x ^= x << 25
    x ^= x >> 27
    r->s = x
    return x * 0x2545F4914F6CDD1Du64
}

/// `[0, n)`, `n > 0`.
pub inline fn rng_below(r: *Rng, n: u64) -> u64 {
    return rng_next(r) % n
}

pub fn fail(const what: string, a: u64, b: u64) -> ! {
    io::println(f"FAIL: {what} ({a}, {b})")
    exit(1)
}

pub inline fn check(ok: bool, const what: string, a: u64, b: u64) {
    if !ok {
        fail(what, a, b)
    }
}

/// Uninitialized storage for `n` elements; never null, also for `n == 0`.
pub fn <T> raw_array(n: usize) -> unsafe *T {
    var unsafe *p = kairo_global_alloc((n + 1) * sizeof T, alignof T)
    if p == &null {
        fail("out of memory", n as u64, 0)
    }

    unsafe {
        return p as unsafe *T
    }
}

pub fn <T> raw_array_free(p: unsafe *T, n: usize) {
    unsafe {
        kairo_global_free(p as unsafe *u8, (n + 1) * sizeof T, alignof T)
    }
}

/// splitmix64 finalizer, for checksums.
pub inline fn tmix(v: u64) -> u64 {
    var x = v + 0x9E3779B97F4A7C15u64
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9u64
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBu64
    return x ^ (x >> 31)
}

pub inline fn fold(h: u64, v: u64) -> u64 {
    return (h ^ v) * 0x100000001B3u64
}

// --- element types ----------------------------------------------------------

pub interface Elem {
    static fn make(k: u64, id: u64) -> Self
    static fn has_id() -> bool
    fn key(const self) -> u64
    fn id(const self) -> u64
}

extend i32 impl Elem {
    static fn make(k: u64, id: u64) -> i32 {
        return k as i32
    }

    static fn has_id() -> bool {
        return false
    }

    fn key(const self) -> u64 {
        return self as u64
    }

    fn id(const self) -> u64 {
        return 0
    }
}

extend u64 impl Elem {
    static fn make(k: u64, id: u64) -> u64 {
        return k
    }

    static fn has_id() -> bool {
        return false
    }

    fn key(const self) -> u64 {
        return self
    }

    fn id(const self) -> u64 {
        return 0
    }
}

/// 8 bytes, ordered by `k` only: `seq` shows stability.
pub struct Pair {
    pub var k: u32
    pub var seq: u32
}

extend Pair impl Elem, Ord {
    static fn make(k: u64, id: u64) -> Pair {
        return Pair { k: k as u32, seq: id as u32 }
    }

    static fn has_id() -> bool {
        return true
    }

    fn key(const self) -> u64 {
        return self.k
    }

    fn id(const self) -> u64 {
        return self.seq
    }


    @no_warn(SC202W)
    fn op == (const self, const o: Self) -> bool {
        return self.k == o.k
    }

    fn op <=> (const self, const o: Self) -> Ordering {
        return self.k <=> o.k
    }
}

/// 64 bytes; the payload repeats the key, so a torn element shows.
pub struct S64 {
    pub var k: u64
    pub var seq: u64
    pub var pad: [u64; 6]
}

extend S64 impl Elem, Ord {
    static fn make(k: u64, id: u64) -> S64 {
        return S64 { k: k, seq: id, pad: [k, id, ~k, ~id, k ^ id, k + id] }
    }

    static fn has_id() -> bool {
        return true
    }

    fn key(const self) -> u64 {
        if self.pad[0] != self.k || self.pad[2] != ~self.k || self.pad[5] != self.k + self.seq {
            fail("torn S64", self.k, self.seq)
        }

        return self.k
    }

    fn id(const self) -> u64 {
        return self.seq
    }


    @no_warn(SC202W)
    fn op == (const self, const o: Self) -> bool {
        return self.k == o.k
    }

    fn op <=> (const self, const o: Self) -> Ordering {
        return self.k <=> o.k
    }
}

pub eval TAG_LIVE: u64 = 0x11FE11FE11FE11FEu64
pub eval TAG_MOVED: u64 = 0x30FED30FED30FED3u64
pub eval TAG_DEAD: u64 = 0xDEADDEADDEADDEADu64

/// Values of `Mo` that exist (constructed and not yet destroyed). A move
/// hands the value to a new object and makes none; a moved-from object
/// holds no value, whether or not it is destroyed.
pub static MO_OBJECTS: i64 = 0

/// Move-only and not relocatable: every relocation runs the move constructor
/// and the destructor, which check the object's state.
pub class Mo impl Elem, Ord {
    pub var k: u64
    pub var seq: u64
    pub var tag: u64

    pub fn Mo(self, k: u64, seq: u64) {
        self.k   = k
        self.seq = seq
        self.tag = TAG_LIVE
        MO_OBJECTS += 1
    }

    @move pub fn Mo(self, other: Self) {
        if other.tag != TAG_LIVE {
            fail("Mo: move from a dead or moved-from object", other.k, other.tag)
        }

        self.k    = other.k
        self.seq  = other.seq
        self.tag  = TAG_LIVE
        other.tag = TAG_MOVED
    }

    pub fn op finally(self) {
        if self.tag != TAG_LIVE && self.tag != TAG_MOVED {
            fail("Mo: double destroy", self.k, self.tag)
        }

        if self.tag == TAG_LIVE {
            MO_OBJECTS -= 1
        }

        self.tag = TAG_DEAD
    }

    pub static fn make(k: u64, id: u64) -> Mo {
        return Mo(k, id)
    }

    pub static fn has_id() -> bool {
        return true
    }

    pub fn key(const self) -> u64 {
        if self.tag != TAG_LIVE {
            fail("Mo: read of a dead or moved-from object", self.k, self.tag)
        }

        return self.k
    }

    pub fn id(const self) -> u64 {
        return self.seq
    }


    @no_warn(SC202W)
    pub fn op == (const self, const o: Self) -> bool {
        return self.key() == o.key()
    }

    pub fn op <=> (const self, const o: Self) -> Ordering {
        return self.key() <=> o.key()
    }
}

/// Move-only with a defaulted move constructor and no destructor: trivially
/// relocatable, so it moves as bytes, and a copy anywhere is a compile error.
pub class MoT impl Elem, Ord {
    pub var k: u64
    pub var seq: u64
    pub var tag: u64

    pub fn MoT(self, k: u64, seq: u64) {
        self.k   = k
        self.seq = seq
        self.tag = TAG_LIVE ^ k
    }

    @move pub fn MoT(self, other: Self) = default

    pub static fn make(k: u64, id: u64) -> MoT {
        return MoT(k, id)
    }

    pub static fn has_id() -> bool {
        return true
    }

    pub fn key(const self) -> u64 {
        if self.tag != (TAG_LIVE ^ self.k) {
            fail("MoT: torn element", self.k, self.tag)
        }

        return self.k
    }

    pub fn id(const self) -> u64 {
        return self.seq
    }


    @no_warn(SC202W)
    pub fn op == (const self, const o: Self) -> bool {
        return self.key() == o.key()
    }

    pub fn op <=> (const self, const o: Self) -> Ordering {
        return self.key() <=> o.key()
    }
}

pub fn <T impl Elem> cmp_by_key(a: *const T, b: *const T) -> Ordering {
    return a->key() <=> b->key()
}

pub fn <T impl Elem> key_of(a: *const T) -> u64 {
    return a->key()
}

// --- patterns ---------------------------------------------------------------

pub eval PATTERNS: u32 = 8

/// Key `i` of `n` in pattern `pat`; keys stay below 2^31.
pub fn pattern_key(pat: u32, i: usize, n: usize, r: *Rng) -> u64 {
    if pat == 0 {
        return i as u64 // sorted
    }

    if pat == 1 {
        return (n - i) as u64 // reversed
    }

    if pat == 2 {
        return 7 // all equal
    }

    if pat == 3 {
        return rng_next(r) >> 63 // two values
    }

    if pat == 4 {
        return (i % 17) as u64 // sawtooth
    }

    if pat == 5 {
        return (if i < n / 2 => i else => n - i) as u64 // organ pipe
    }

    if pat == 6 {
        return rng_next(r) >> 34 // random
    }

    return rng_next(r) % 8 // few distinct
}

/// Constructs `n` elements in pattern `pat`, ids ascending with the index.
/// Returns the order-independent checksum of the elements.
pub fn <T impl Elem> fill_pattern(a: unsafe *T, n: usize, pat: u32, r: *Rng) -> u64 {
    var sum: u64 = 0
    var i: usize = 0
    unsafe {
        while i < n {
            var k = pattern_key(pat, i, n, r)
            __builtin_construct_at<T>((a + i) as unsafe *u8, T::make(k, i as u64))
            sum += tmix(k ^ tmix(a[i].id()))
            i += 1
        }
    }

    return sum
}

pub fn <T impl Elem> destroy_all(a: unsafe *T, n: usize) {
    eval if !__builtin_is_trivially_destructible<T>() {
        var i: usize = 0
        unsafe {
            while i < n {
                __builtin_destruct_at(&a[i])
                i += 1
            }
        }
    }
}

/// The range is sorted by key, holds the elements `fill_pattern` made, and
/// (when `stable` and the type carries ids) keeps equal keys in input order.
pub fn <T impl Elem> verify(a: unsafe *T, n: usize, sum: u64, stable: bool, what: u64) {
    var got: u64 = 0
    var i: usize = 0
    unsafe {
        while i < n {
            var k = a[i].key()
            got += tmix(k ^ tmix(a[i].id()))
            if i > 0 {
                var pk = a[i - 1].key()
                if pk > k {
                    fail("not sorted", what, i as u64)
                }

                if stable && T::has_id() && pk == k && a[i - 1].id() >= a[i].id() {
                    fail("not stable", what, i as u64)
                }
            }

            i += 1
        }
    }

    if got != sum {
        fail("not a permutation of the input", what, n as u64)
    }
}

/// The sizes the pattern drivers walk: 0..64, then 2^k - 1, 2^k, 2^k + 1 for
/// k in 7..=max_log. Returns the next size, or 0 when done.
pub fn next_size(n: usize, max_log: u32) -> usize {
    if n < 64 {
        return n + 1
    }

    var k: u32 = 7
    while k <= max_log {
        var p = 1usize << k
        if n < p - 1 {
            return p - 1
        }

        if n < p + 1 {
            return n + 1
        }

        k += 1
    }

    return 0
}

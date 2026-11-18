// Support for the ported slice tests: an instrumented move-only element, a
// seeded generator, a check helper, and slice builders. Not a test.

import std::io
ffi "c" import "stdlib.h"

pub eval ST_LIVE:  u64 = 0x51A7E51A7E51A7E5u64
pub eval ST_MOVED: u64 = 0x30FED30FED30FED3u64
pub eval ST_DEAD:  u64 = 0xDEADDEADDEADDEADu64

/// Objects constructed or moved into existence and not yet destroyed.
pub static LIVE: i64 = 0
/// Constructions from a key, moves, destructions, and states found wrong.
pub static MADE: i64 = 0
pub static MOVES: i64 = 0
pub static DROPS: i64 = 0
pub static BAD: i64 = 0

/// A move-only element with a key and the order it was made in (`id`). A move
/// out of a dead object, a read of a moved-from or dead one and a second
/// destruction each count in `BAD`.
pub class Inst {
    pub var k: i64
    pub var id: i64
    var tag: u64

    pub fn Inst(self, k: i64, id: i64) {
        self.k   = k
        self.id  = id
        self.tag = ST_LIVE
        LIVE += 1
        MADE += 1
    }

    @move pub fn Inst(self, other: Self) {
        if other.tag != ST_LIVE {
            BAD += 1
        }

        self.k    = other.k
        self.id   = other.id
        self.tag  = ST_LIVE
        other.tag = ST_MOVED
        LIVE += 1
        MOVES += 1
    }

    pub fn op finally(self) {
        if self.tag != ST_LIVE && self.tag != ST_MOVED {
            BAD += 1
        }

        self.tag = ST_DEAD
        LIVE -= 1
        DROPS += 1
    }

    pub fn key(const self) -> i64 {
        if self.tag != ST_LIVE {
            BAD += 1
        }

        return self.k
    }

    @no_warn(SC202W)
    pub fn op == (const self, const o: Self) -> bool {
        return self.key() == o.key()
    }

    pub fn op <=> (const self, const o: Self) -> Ordering {
        return self.key() <=> o.key()
    }
}

pub fn inst_by_key(a: *const Inst, b: *const Inst) -> Ordering {
    return a->key() <=> b->key()
}

pub fn inst_key_of(a: *const Inst) -> i64 {
    return a->key()
}

/// An instrumented element that is also copyable, so `fill` and `to_owned`
/// can be run on it. `COPIES` counts duplications.
pub static COPIES: i64 = 0

pub class Dup {
    pub var k: i64
    var tag: u64

    pub fn Dup(self, k: i64) {
        self.k   = k
        self.tag = ST_LIVE
        LIVE += 1
    }

    @move pub fn Dup(self, other: Self) {
        if other.tag != ST_LIVE {
            BAD += 1
        }

        self.k    = other.k
        self.tag  = ST_LIVE
        other.tag = ST_MOVED
        LIVE += 1
    }

    pub fn copy(const self) -> Dup {
        if self.tag != ST_LIVE {
            BAD += 1
        }

        COPIES += 1
        return Dup(self.k)
    }

    pub fn op finally(self) {
        if self.tag != ST_LIVE && self.tag != ST_MOVED {
            BAD += 1
        }

        self.tag = ST_DEAD
        LIVE -= 1
    }
}

/// A distinct exit code per failing check: the first failure ends the program.
pub fn fail(const what: string, code: i32) -> ! {
    io::println(f"FAIL: {what}")
    exit(code)
}

pub fn check(ok: bool, const what: string, code: i32) {
    if !ok {
        fail(what, code)
    }
}

/// True when no instrumented object is alive and none was misused.
pub fn clean() -> bool {
    return LIVE == 0 && BAD == 0
}

pub fn check_clean(const what: string, code: i32) {
    if LIVE != 0 {
        io::println(f"FAIL: {what}: {LIVE} objects alive")
        exit(code)
    }

    if BAD != 0 {
        io::println(f"FAIL: {what}: {BAD} bad states")
        exit(code)
    }
}

/// xorshift64*.
pub struct Rng {
    pub var s: u64
}

pub fn rng_new(seed: u64) -> Rng {
    return Rng { s: seed | 1 }
}

pub fn rng_next(r: *Rng) -> u64 {
    var x = r->s
    x ^= x >> 12
    x ^= x << 25
    x ^= x >> 27
    r->s = x
    return x * 0x2545F4914F6CDD1Du64
}

pub fn rng_below(r: *Rng, n: u64) -> u64 {
    return rng_next(r) % n
}

/// `n` instrumented elements with keys `first, first + step, ...` and ids 0..n.
pub fn insts(n: usize, first: i64, step: i64) -> [Inst] {
    var v: [Inst]
    for var i: usize = 0; i < n; ++i {
        v.push(Inst(first + (i as i64) * step, i as i64))
    }

    return v
}

/// The keys of `s` as a vector of `i64`.
pub fn keys(const s: [const Inst;]) -> [i64] {
    var out: [i64]
    for var i: usize = 0; i < s.size(); ++i {
        out.push(s[i].key())
    }

    return out
}

/// Words "w0", "w1", ... for the string cases.
pub fn words(n: usize) -> [string] {
    var v: [string]
    for var i: usize = 0; i < n; ++i {
        v.push(f"w{i}")
    }

    return v
}

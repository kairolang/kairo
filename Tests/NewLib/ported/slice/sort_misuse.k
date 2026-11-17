// Sorting with an ordering that is not a total order must not corrupt: no
// access outside the slice, no element lost, duplicated or destroyed twice,
// no read of a moved-from object, and the live count returns to zero. The
// result of such a sort has no defined order, so each case checks only that
// the output is a permutation of the input. The orderings are: always Less,
// always Greater, always Equal, random, cyclic (a < b < c < a), alternating
// answers, "less or equal" reported as Less for equal keys, a sort_by_key
// whose key changes on every call, and a type whose own `<=>` is random
// (sort and sort_unstable). Lengths run 0 to 40 and around powers of two up
// to 2049, over the ascending, descending, all-equal and random patterns.
//
// Cases from Rust library/alloctests/tests/sort/ (ord_violation, random comparator)
// Cases from libc++ test/std/algorithms/alg.sorting/alg.sort/ (invalid comparators)

import self::Inputs::inst::*
import std::io

static CALLS: u64 = 0
static WILD_RNG: u64 = 0x9E3779B97F4A7C15u64

fn wild_next() -> u64 {
    var x = WILD_RNG
    x ^= x >> 12
    x ^= x << 25
    x ^= x >> 27
    WILD_RNG = x
    return x * 0x2545F4914F6CDD1Du64
}

fn always_less(a: *const Inst, b: *const Inst) -> Ordering {
    return Ordering::Less
}

fn always_greater(a: *const Inst, b: *const Inst) -> Ordering {
    return Ordering::Greater
}

fn always_equal(a: *const Inst, b: *const Inst) -> Ordering {
    return Ordering::Equal
}

fn random_order(a: *const Inst, b: *const Inst) -> Ordering {
    var x = wild_next() % 3
    return (if x == 0 => Ordering::Less else if x == 1 => Ordering::Equal else => Ordering::Greater)
}

/// a < b < c < a on the keys mod 3.
fn cyclic(a: *const Inst, b: *const Inst) -> Ordering {
    var x = a->key() % 3
    var y = b->key() % 3
    if x == y {
        return Ordering::Equal
    }

    return (if (x + 1) % 3 == y => Ordering::Less else => Ordering::Greater)
}

fn alternating(a: *const Inst, b: *const Inst) -> Ordering {
    CALLS += 1
    if CALLS % 2 == 0 {
        return a->key() <=> b->key()
    }

    return b->key() <=> a->key()
}

/// "Less or equal": equal keys report Less in both directions.
fn less_or_equal(a: *const Inst, b: *const Inst) -> Ordering {
    return (if a->key() <= b->key() => Ordering::Less else => Ordering::Greater)
}

fn drifting_key(a: *const Inst) -> i64 {
    return a->key() + (wild_next() % 50) as i64
}

fn from_pattern(n: usize, pat: u32) -> [Inst] {
    var v: [Inst]
    for var i: usize = 0; i < n; ++i {
        var k: i64 = 0
        if pat == 0 {
            k = i as i64
        } else if pat == 1 {
            k = (n - i) as i64
        } else if pat == 2 {
            k = 5
        } else {
            k = (wild_next() % 1000) as i64
        }

        v.push(Inst(k, i as i64))
    }

    return v
}

/// `v` still holds each of the `n` ids once.
fn permutation(const v: [Inst], n: usize, const what: string, code: i32) {
    if v.size() != n {
        fail(f"{what} changes the length", code)
    }

    var seen: [bool]
    for var i: usize = 0; i < n; ++i {
        seen.push(false)
    }

    for var i: usize = 0; i < n; ++i {
        var id = v[i].id
        if id < 0 || id >= n as i64 || seen[id as usize] {
            fail(f"{what} loses or duplicates an element", code + 1)
        }

        seen[id as usize] = true
    }
}

fn misuse_by(const what: string, cmp: fn(*const Inst, *const Inst) -> Ordering, code: i32) {
    var n: usize = 0
    loop {
        for var pat: u32 = 0; pat < 4; ++pat {
            var v = from_pattern(n, pat)
            var s: [Inst;] = v
            s.sort_by(cmp)
            permutation(v, n, what, code)
        }

        if n < 40 {
            n += 1
        } else if n == 40 {
            n = 63
        } else if n == 63 {
            n = 64
        } else if n == 64 {
            n = 65
        } else if n == 65 {
            n = 127
        } else if n == 127 {
            n = 128
        } else if n == 128 {
            n = 129
        } else if n == 129 {
            n = 1024
        } else if n == 1024 {
            n = 2049
        } else {
            break
        }
    }

    check_clean(what, code + 2)
}

fn key_misuse() {
    var n: usize = 0
    loop {
        for var pat: u32 = 0; pat < 4; ++pat {
            var v = from_pattern(n, pat)
            var s: [Inst;] = v
            s.sort_by_key(drifting_key)
            permutation(v, n, "sort_by_key with a drifting key", 100)
        }

        if n < 70 {
            n += 3
        } else if n < 600 {
            n *= 3
        } else {
            break
        }
    }

    check_clean("sort_by_key with a drifting key", 102)
}

/// An element whose own ordering is random.
class Wild impl Ord {
    pub var id: i64
    var tag: u64

    pub fn Wild(self, id: i64) {
        self.id  = id
        self.tag = ST_LIVE
        LIVE += 1
    }

    @move pub fn Wild(self, other: Self) {
        if other.tag != ST_LIVE {
            BAD += 1
        }

        self.id   = other.id
        self.tag  = ST_LIVE
        other.tag = ST_MOVED
        LIVE += 1
    }

    pub fn op finally(self) {
        if self.tag != ST_LIVE && self.tag != ST_MOVED {
            BAD += 1
        }

        self.tag = ST_DEAD
        LIVE -= 1
    }

    @no_warn(SC202W)
    pub fn op == (const self, const o: Self) -> bool {
        return wild_next() % 2 == 0
    }

    pub fn op <=> (const self, const o: Self) -> Ordering {
        if self.tag != ST_LIVE || o.tag != ST_LIVE {
            BAD += 1
        }

        var x = wild_next() % 3
        return (if x == 0 => Ordering::Less else if x == 1 => Ordering::Equal else => Ordering::Greater)
    }
}

fn wild_elements() {
    var n: usize = 0
    loop {
        for var round: u32 = 0; round < 2; ++round {
            var v: [Wild]
            for var i: usize = 0; i < n; ++i {
                v.push(Wild(i as i64))
            }

            var s: [Wild;] = v
            if round == 0 {
                s.sort()
            } else {
                s.sort_unstable()
            }

            if v.size() != n {
                fail("sort of a random ordering changes the length", 110)
            }

            var seen: [bool]
            for var i: usize = 0; i < n; ++i {
                seen.push(false)
            }

            for var i: usize = 0; i < n; ++i {
                var id = v[i].id
                if id < 0 || id >= n as i64 || seen[id as usize] {
                    fail("sort of a random ordering loses or duplicates an element", 111)
                }

                seen[id as usize] = true
            }
        }

        if n < 40 {
            n += 1
        } else if n == 40 {
            n = 64
        } else if n == 64 {
            n = 65
        } else if n == 65 {
            n = 128
        } else if n == 128 {
            n = 129
        } else if n == 129 {
            n = 1024
        } else if n == 1024 {
            n = 2049
        } else {
            break
        }
    }

    check_clean("sort of a random ordering", 112)
}

fn string_misuse() {
    var v: [string]
    for var i: usize = 0; i < 300; ++i {
        v.push(f"s{wild_next() % 1000}")
    }

    var s: [string;] = v
    s.sort_by(string_random)
    check(v.size() == 300, "string sort_by with a random comparator keeps the length", 120)
    var total: usize = 0
    for var i: usize = 0; i < v.size(); ++i {
        total += v[i].size()
        if v[i].size() < 2 || v[i][0] != 's' {
            fail("a string was corrupted by a random comparator", 121)
        }
    }

    check(total > 600, "no string was emptied", 122)
}

fn string_random(a: *const string, b: *const string) -> Ordering {
    var x = wild_next() % 3
    return (if x == 0 => Ordering::Less else if x == 1 => Ordering::Equal else => Ordering::Greater)
}

fn main() -> i32 {
    misuse_by("always Less", always_less, 10)
    misuse_by("always Greater", always_greater, 20)
    misuse_by("always Equal", always_equal, 30)
    misuse_by("random", random_order, 40)
    misuse_by("cyclic", cyclic, 50)
    misuse_by("alternating", alternating, 60)
    misuse_by("less or equal", less_or_equal, 70)
    key_misuse()
    wild_elements()
    string_misuse()
    io::println("sort_misuse ok")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: sort_misuse ok

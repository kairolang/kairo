// Differential fuzz: a seeded xorshift stream of operations applied to a
// Kairo vector and to a std::vector of the keys it should hold
// (inputs/fuzz_model.h), with the size, the capacity bound and every key
// compared after each step. Element types: i32, Tracked (moved element by
// element), RTracked (moved by bytes) and string; string has no dedup here,
// since it does not meet Eq as a bound. Removals are kept proportionate so
// the vector holds tens of elements, not a handful. After each run no
// Tracked is left alive and none was destroyed twice or used after a move.
//
// With no argument it runs a short pass; with one (`fuzz.exe long`) it runs
// seeds until a failure or until stopped, printing the operation count. The
// body is a macro: a generic function cannot call the vector's extend-block
// members.

ffi "c++" import "fuzz_model.h"

import self::inputs::elems::*
import std::io

class Rng {
    var s: u64

    pub fn Rng(self, seed: u64) {
        self.s = seed | 1
    }

    pub fn next(self) -> u64 {
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return self.s
    }

    /// Uniform enough in [0, n), n > 0.
    pub fn below(self, n: usize) -> usize {
        return (self.next() % (n as u64)) as usize
    }
}

macro check_fn!(CK, E) {
fn CK(const v: [E]) -> i64 {
    if v.size() != model_size() || v.capacity() < v.size() {
        return 1
    }

    for var i: usize = 0; i < v.size(); ++i {
        if v[i].key() != model_at(i) {
            return 1
        }
    }

    return 0
}
}

// The operations every element type takes. `sel` is in [0, 20).
macro core_ops!(E) {
        if sel <= 2 {
            v.push(E::make(k))
            model_push(k)
        }

        if sel == 3 {
            var i = rng.below(n + 1)
            v.insert(i, E::make(k))
            model_insert(i, k)
        }

        if sel == 4 {
            var o: [E]
            var m = rng.below(6)
            for var j: usize = 0; j < m; ++j {
                o.push(E::make(k + j as i64))
                model_push(k + j as i64)
            }

            v.append(o)
        }

        if sel == 6 && n > 0 {
            var x = v.pop()
            var want = model_pop()
            if x? {
                if x.key() != want {
                    bad += 1
                }
            } else {
                bad += 1
            }
        }

        if sel == 7 && n > 0 {
            var i = rng.below(n)
            var x = v.remove(i)
            if x.key() != model_remove(i) {
                bad += 1
            }
        }

        if sel == 8 && n > 0 {
            var i = rng.below(n)
            var x = v.swap_remove(i)
            if x.key() != model_swap_remove(i) {
                bad += 1
            }
        }

        if sel == 9 {
            var t = n - rng.below(n / 4 + 1) + rng.below(3)
            v.truncate(t)
            model_truncate(t)
        }

        if sel == 10 {
            var lo   = rng.below(n + 1)
            var room = n - lo
            if room > 8 {
                room = 8
            }

            var hi = lo + rng.below(room + 1)
            var f  = rng.below(hi - lo + 1)
            var b  = rng.below(hi - lo - f + 1)
            {
                var d = v.drain(lo..hi)
                for var j: usize = 0; j < f; ++j {
                    var x = d.next()
                    if x? {
                        if x.key() != model_at(lo + j) {
                            bad += 1
                        }
                    } else {
                        bad += 1
                    }
                }

                for var j: usize = 0; j < b; ++j {
                    var x = d.next_back()
                    if x? {
                        if x.key() != model_at(hi - 1 - j) {
                            bad += 1
                        }
                    } else {
                        bad += 1
                    }
                }

                if d.remaining() != hi - lo - f - b {
                    bad += 1
                }
            }

            model_erase(lo, hi)
        }

        if sel == 11 && rng.below(4) == 0 {
            var mode = rng.below(4) as i32
            if mode == 0 {
                v.retain(fn (p: *const E) -> bool { return p->key() % 3 != 0 })
            } else if mode == 1 {
                v.retain(fn (p: *const E) -> bool { return p->key() % 2 == 0 })
            } else if mode == 2 {
                v.retain(fn (p: *const E) -> bool { return false })
            } else {
                v.retain(fn (p: *const E) -> bool { return true })
            }

            model_retain(mode)
        }

        if sel == 13 {
            v.reserve(rng.below(300))
        }

        if sel == 14 {
            v.shrink_to_fit()
            if v.capacity() != v.size() {
                bad += 1
            }
        }

        if sel == 15 && n > 0 {
            var i = rng.below(n)
            v[i] = E::make(k)
            model_set(i, k)
        }

        if sel == 18 && rng.below(8) == 0 {
            v.clear()
            model_reset()
        }

        if sel == 19 {
            var w = v
            v = w
        }
}

// The operation that compares elements.
macro eq_ops!(E) {
        if sel == 12 {
            v.dedup()
            model_dedup()
        }
}

// The operations that copy elements.
macro copy_ops!(E, CK) {
        if sel == 5 {
            var lo = rng.below(n + 1)
            var hi = lo + rng.below(n - lo + 1)
            v.extend_from(v[lo..hi])
            model_extend_self(lo, hi)
        }

        if sel == 16 {
            var t = n - rng.below(n / 4 + 1) + rng.below(8)
            v.resize(t, E::make(k))
            model_resize(t, k)
        }

        if sel == 17 {
            var c = v.copy()
            if c.capacity() != c.size() {
                bad += 1
            }

            bad += CK(c)
        }
}

macro fuzz_fn!(FN, CK, E, OPS) {
fn FN(const name: string, seed: u64, steps: u64) -> i64 {
    model_reset()
    var rng      = Rng(seed)
    var bad: i64 = 0
    {
        var v: [E]
        for var step: u64 = 0; step < steps; ++step {
            var n  = v.size()
            var sel = rng.below(20)
            if n > 150 && sel <= 5 {
                sel += 6
            }

            var span: usize = 1000
            if rng.below(4) == 0 {
                span = 8
            }

            var k = rng.below(span) as i64
            core_ops!(E)
            OPS
            if CK(v) != 0 {
                bad += 1
            }

            if bad != 0 {
                io::println(f"{name}: seed {seed} step {step} op {sel}: mismatch")
                break
            }
        }
    }

    if LIVE != 0 || ERRS != 0 {
        io::println(f"{name}: seed {seed}: live={LIVE} errs={ERRS}")
        LIVE = 0
        ERRS = 0
        bad += 1
    }

    return bad
}
}

check_fn!(ck_i32, i32)
check_fn!(ck_tracked, Tracked)
check_fn!(ck_rtracked, RTracked)
check_fn!(ck_string, string)
fuzz_fn!(fuzz_i32, ck_i32, i32, copy_ops!(i32, ck_i32) eq_ops!(i32))
fuzz_fn!(fuzz_tracked, ck_tracked, Tracked, copy_ops!(Tracked, ck_tracked) eq_ops!(Tracked))
fuzz_fn!(fuzz_rtracked, ck_rtracked, RTracked, copy_ops!(RTracked, ck_rtracked) eq_ops!(RTracked))
fuzz_fn!(fuzz_string, ck_string, string, copy_ops!(string, ck_string))

fn run(seeds: u64, steps: u64) -> i64 {
    var bad: i64 = 0
    for var s: u64 = 1; s <= seeds && bad == 0; ++s {
        var seed = s * 0x9E3779B97F4A7C15
        bad += fuzz_i32("i32", seed, steps)
        bad += fuzz_tracked("Tracked", seed, steps)
        bad += fuzz_rtracked("RTracked", seed, steps)
        bad += fuzz_string("string", seed, steps)
    }

    return bad
}

fn main(argc: i32) -> i32 {
    if argc > 1 {
        // Seed after seed until stopped, the running count printed after
        // each one.
        var steps: u64 = 20000
        var bad: i64   = 0
        for var s: u64 = 1; bad == 0; ++s {
            var seed = s * 0x9E3779B97F4A7C15
            bad += fuzz_i32("i32", seed, steps)
            bad += fuzz_tracked("Tracked", seed, steps)
            bad += fuzz_rtracked("RTracked", seed, steps)
            bad += fuzz_string("string", seed, steps)
            io::println(f"{s * steps * 4} operations, {bad} failures")
        }

        return bad as i32
    }

    var bad = run(3, 4000)
    if bad == 0 {
        io::println("fuzz: ok")
    }

    return bad as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s --cxx-include %S/inputs -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: fuzz: ok

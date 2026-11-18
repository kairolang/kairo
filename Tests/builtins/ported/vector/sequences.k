// Sequences of operations: a block with spare capacity stays where it is
// through every operation that fits, zero-size-like elements, and a long
// deterministic run of mixed operations compared after each step with a
// plain array model, with the live-object count of the counting classes
// equal to the length after every step (a leak or a double destroy breaks it
// at the operation that caused it).
//
// Cases from Rust library/alloctests/tests/vec.rs
//   (test_stable_pointers, zero_sized_values, test_zero_sized_vec_push)
// Cases from libc++ test/std/containers/sequences/vector/vector.modifiers/
//   (insert and erase sequences)
//
// Rust's splice, extract_if and spare_capacity_mut steps have no counterpart.

import self::inputs::counted::*

struct Unit {
}

fn <E impl Elem> stable_block(const tag: string) requires E impl Copyable {
    reset()
    {
        var v = Vector<E>::with_capacity(128)
        v.push(E::make(13))
        var base = v.data()
        var first = &v[0] as usize
        var ok = true
        v.push(E::make(1))
        v.push(E::make(2))
        v.insert(1, E::make(1))
        ok = ok && v.data() == base
        var r = v.remove(1)
        var p? = v.pop()
        v.push(E::make(1))
        var s = v.swap_remove(1)
        ok = ok && v.data() == base && v.size() == 2
        v.append(fill<E>(2))
        v.extend_from(v[0..2])
        v.truncate(2)
        v.resize(12, E::make(42))
        v.resize(2, E::make(42))
        v.reserve(32)
        v.reserve(128)
        ok = ok && v.data() == base && v.capacity() == 128
        v.resize(10)
        {
            var d = v.drain(5..8)
            var a? = d.next()
        }

        v.retain(fn (q: *const E) -> bool { return true })
        v.clear()
        v.push(E::make(13))
        expect(ok, f"{tag}: the block stays put while the elements fit")
        expect(v.data() == base && (&v[0] as usize) == first, f"{tag}: element 0 stays at its address")
        expect(v[0].key() == 13, f"{tag}: and holds its value")
    }

    expect_clean(f"{tag}: stable block")
}

fn units() {
    var v: [Unit]
    expect(v.size() == 0 && v.pop() == null, "unit: empty")
    v.push(Unit {})
    v.push(Unit {})
    expect(v.size() == 2, "unit: two pushed")
    var a? = v.pop()
    var b? = v.pop()
    var c? = v.pop()
    expect(a? && b? && !c? && v.is_empty(), "unit: popped twice, then null")
    var n: i64 = 0
    v.push(Unit {})
    for const *x in v {
        n += 1
    }

    v.push(Unit {})
    for *x in v {
        n += 1
    }

    expect(n == 3, "unit: iteration counts the elements")
    for var i: i32 = 0; i < 1000; ++i {
        v.push(Unit {})
    }

    expect(v.size() == 1002, "unit: a thousand more")
    v.insert(500, Unit {})
    var r = v.remove(0)
    v.truncate(10)
    expect(v.size() == 10, "unit: insert, remove and truncate")
    v.clear()
    expect(v.is_empty(), "unit: cleared")
}

static SEED: u64 = 88172645463325252

fn next_random(bound: u64) -> u64 {
    SEED ^= SEED << 13
    SEED ^= SEED >> 7
    SEED ^= SEED << 17
    return SEED % bound
}

static MODEL: [i64; 2048]
static LEN: usize = 0

fn model_insert(at: usize, x: i64) {
    for var i: usize = LEN; i > at; --i {
        MODEL[i] = MODEL[i - 1]
    }

    MODEL[at] = x
    LEN += 1
}

fn model_remove(at: usize) {
    for var i: usize = at; i + 1 < LEN; ++i {
        MODEL[i] = MODEL[i + 1]
    }

    LEN -= 1
}

fn <E impl Elem> same_as_model(const v: [E]) -> bool {
    if v.size() != LEN {
        return false
    }

    for var i: usize = 0; i < LEN; ++i {
        if v[i].key() != MODEL[i] {
            return false
        }
    }

    return true
}

fn <E impl Elem> keep_odd_key(p: *const E) -> bool {
    return p->key() % 2 != 0
}

fn <E impl Elem> mixed_operations(const tag: string, counting: bool) requires E impl Eq && E impl Copyable {
    reset()
    SEED = 88172645463325252
    LEN = 0
    {
        var v: [E]
        var step = 0
        var bad = 0
        var live_bad = 0
        for var iter = 0; iter < 4000; ++iter {
            var kind = next_random(14)
            var val = next_random(7) as i64
            var n = v.size()
            if kind == 0 || n == 0 {
                if LEN < 1500 {
                    v.push(E::make(val))
                    model_insert(LEN, val)
                }
            } else if kind == 1 {
                var x? = v.pop()
                if !x? || unwrap!(x).key() != MODEL[LEN - 1] {
                    bad += 1
                }

                LEN -= 1
            } else if kind == 2 {
                var at = next_random(n as u64 + 1) as usize
                if LEN < 1500 {
                    v.insert(at, E::make(val))
                    model_insert(at, val)
                }
            } else if kind == 3 {
                var at = next_random(n as u64) as usize
                var x = v.remove(at)
                if x.key() != MODEL[at] {
                    bad += 1
                }

                model_remove(at)
            } else if kind == 4 {
                var at = next_random(n as u64) as usize
                var x = v.swap_remove(at)
                if x.key() != MODEL[at] {
                    bad += 1
                }

                MODEL[at] = MODEL[LEN - 1]
                LEN -= 1
            } else if kind == 5 {
                var to = next_random(n as u64 + 1) as usize
                v.truncate(to)
                LEN = to
            } else if kind == 6 {
                v.retain(keep_odd_key<E>)
                var w: usize = 0
                for var i: usize = 0; i < LEN; ++i {
                    if MODEL[i] % 2 != 0 {
                        MODEL[w] = MODEL[i]
                        w += 1
                    }
                }

                LEN = w
            } else if kind == 7 {
                v.dedup()
                var w: usize = 1
                for var i: usize = 1; i < LEN; ++i {
                    if MODEL[i] != MODEL[w - 1] {
                        MODEL[w] = MODEL[i]
                        w += 1
                    }
                }

                LEN = w
            } else if kind == 8 {
                var lo = next_random(n as u64 + 1) as usize
                var hi = lo + next_random((n - lo) as u64 + 1) as usize
                {
                    var d = v.drain(lo..hi)
                    var take = next_random((hi - lo) as u64 + 1) as usize
                    for var t: usize = 0; t < take; ++t {
                        var x? = d.next()
                    }
                }

                for var i: usize = 0; i + hi < LEN; ++i {
                    MODEL[lo + i] = MODEL[hi + i]
                }

                LEN -= hi - lo
            } else if kind == 9 {
                var lo = next_random(n as u64 + 1) as usize
                var hi = lo + next_random((n - lo) as u64 + 1) as usize
                if LEN + (hi - lo) <= 1500 {
                    v.extend_from(v[lo..hi])
                    for var i: usize = 0; i < hi - lo; ++i {
                        MODEL[LEN + i] = MODEL[lo + i]
                    }

                    LEN += hi - lo
                }
            } else if kind == 10 {
                var to = next_random(40) as usize + n
                if to <= 1500 {
                    v.resize(to, E::make(val))
                    for var i: usize = LEN; i < to; ++i {
                        MODEL[i] = val
                    }

                    LEN = to
                }
            } else if kind == 11 {
                var other = fill<E>(next_random(5) as i64)
                var m = other.size()
                if LEN + m <= 1500 {
                    v.append(move(other))
                    for var i: usize = 0; i < m; ++i {
                        MODEL[LEN + i] = i as i64
                    }

                    LEN += m
                }
            } else if kind == 12 {
                v.shrink_to_fit()
            } else {
                if next_random(8) == 0 {
                    v.clear()
                    LEN = 0
                }
            }

            if !same_as_model<E>(v) {
                bad += 1
            }

            if counting && LIVE != v.size() as i64 {
                live_bad += 1
            }

            step += 1
        }

        expect(bad == 0, f"{tag}: contents equal the model after every one of 4000 steps")
        expect(live_bad == 0, f"{tag}: live objects equal the length after every step")
    }

    expect_clean(f"{tag}: mixed operations")
}

fn main() -> i32 {
    stable_block<i32>("i32")
    stable_block<string>("string")
    stable_block<Counted>("Counted")
    stable_block<RCounted>("RCounted")
    units()
    mixed_operations<i32>("i32", false)
    mixed_operations<string>("string", false)
    mixed_operations<Counted>("Counted", true)
    mixed_operations<RCounted>("RCounted", true)
    return finish()
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe

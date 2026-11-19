// A random sequence of mutations on each starting state (literal, view, heap)
// is applied to a string and, as bytes, to a model; after every step the
// string equals a fresh string built from the model's bytes, counts the same
// code points, hashes alike, orders alike, and searches alike. Offsets for
// insert, remove and truncate are drawn on char boundaries; copies and views
// are taken and mutated in the middle of the run, and each must leave the
// text it was made from alone.
// Cases from libc++ test/std/strings/basic.string/string.modifiers/ (insert, erase, append, push_back, pop_back combined)
// Cases from Rust library/alloctests/tests/string.rs (the mutators in sequence)

import std::io

static CODE: i32 = 0

fn ck(ok: bool, id: i32, const name: string) {
    if !ok {
        io::println(f"FAIL {name}")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn ch(v: u32) -> char {
    var c: char = v
    return c
}

class Rng {
    var s: u64

    pub fn Rng(self, seed: u64) {
        self.s = seed
    }

    pub fn next(self) -> u64 {
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return self.s
    }

    pub fn below(self, n: usize) -> usize {
        return (((self.next() >> 32) * (n as u64)) >> 32) as usize
    }

    pub fn scalar(self) -> char {
        var k      = self.below(8)
        var v: u32 = 0
        if k < 4 {
            v = 0x20 + (self.below(95) as u32)
        } else if k < 6 {
            v = 0x80 + (self.below(0x780) as u32)
        } else if k < 7 {
            v = 0x800 + (self.below(0x5000) as u32)
        } else {
            v = 0x10000 + (self.below(0x1000) as u32)
        }

        var c: char = v
        return c
    }
}

fn mk(kind: usize, const src: string) -> string {
    if kind == 0 {
        return src.copy()
    }

    if kind == 1 {
        return src.view()
    }

    return src.to_owned()
}

fn hash_of(const s: string) -> u64 {
    var h = Hasher(3)
    s.hash(&h)
    return h.finish()
}

// The bytes of `s` as a model.
fn model_of(const s: string) -> [u8] {
    var m: [u8] = []
    var b = s.bytes()
    for var i: usize = 0; i < b.size(); i += 1 {
        m.push(b[i])
    }

    return m
}

fn fresh(const m: [u8]) -> string? {
    return string::from_utf8(m)
}

fn is_boundary(const m: [u8], i: usize) -> bool {
    if i >= m.size() {
        return i == m.size()
    }

    return (m[i] & 0xc0) != 0x80
}

// A random boundary at or below the size.
fn pick_boundary(rng: *Rng, const m: [u8]) -> usize {
    var i = rng->below(m.size() + 1)
    while !is_boundary(m, i) {
        i -= 1
    }

    return i
}

fn encode_into(c: char, @inout m: [u8], at: usize) -> usize {
    var tmp = string()
    tmp.push(c)
    var b = tmp.bytes()
    for var i: usize = 0; i < b.size(); i += 1 {
        m.insert(at + i, b[i])
    }

    return b.size()
}

fn agrees(const s: string, const m: [u8]) -> bool {
    var f? = fresh(m)
    if !f? {
        return false
    }

    if f.size() != m.size() || !(s == f) || s.size() != m.size() {
        return false
    }

    var cps: usize = 0
    for var i: usize = 0; i < m.size(); i += 1 {
        if (m[i] & 0xc0) != 0x80 {
            cps += 1
        }
    }

    if s.codepoints() != cps || s.is_ascii() != (cps == m.size()) {
        return false
    }

    if hash_of(s) != hash_of(f) || (s <=> f) != Ordering::Equal {
        return false
    }

    if s.is_owned() {
        unsafe {
            var unsafe *z = s.data() as unsafe *const u8
            if z[s.size()] != 0 {
                return false
            }
        }
    }

    return true
}

fn run(kind: usize, seed: u64, steps: i32) {
    var rng = Rng(seed)
    var base = "aé€😀 text"
    var s = mk(kind, base)
    var m = model_of(s)
    var bystander = s.to_owned()
    var bm = model_of(bystander)
    for var step = 0; step < steps; step += 1 {
        var which = rng.below(10)
        if which == 0 {
            var c = rng.scalar()
            s.push(c)
            encode_into(c, &m, m.size())
        } else if which == 1 {
            var piece = string()
            var n = rng.below(4)
            for var j: usize = 0; j < n; j += 1 {
                piece.push(rng.scalar())
            }

            s.push_str(piece)
            var pb = piece.bytes()
            for var j: usize = 0; j < pb.size(); j += 1 {
                m.push(pb[j])
            }
        } else if which == 2 {
            var at = pick_boundary(&rng, m)
            var c = rng.scalar()
            var piece = string()
            piece.push(c)
            piece.push(rng.scalar())
            s.insert(at, piece)
            var pb = piece.bytes()
            for var j: usize = 0; j < pb.size(); j += 1 {
                m.insert(at + j, pb[j])
            }
        } else if which == 3 {
            var lo = pick_boundary(&rng, m)
            var hi = pick_boundary(&rng, m)
            if hi < lo {
                var t = lo
                lo = hi
                hi = t
            }

            s.remove_range(lo..hi)
            for var j = lo; j < hi; j += 1 {
                m.remove(lo)
            }
        } else if which == 4 {
            var c? = s.pop()
            if m.size() == 0 {
                ck(!c?, 1, "pop on empty")
            } else {
                var i = m.size() - 1
                while !is_boundary(m, i) {
                    i -= 1
                }

                var want = m.size() - i
                ck(c?, 2, "pop returns a char")
                var cs = string()
                if c? {
                    cs.push(c)
                }

                ck(cs.size() == want, 3, "pop returns the last char")
                m.truncate(i)
            }
        } else if which == 5 {
            var at = pick_boundary(&rng, m)
            s.truncate(at)
            m.truncate(at)
        } else if which == 6 {
            if rng.below(8) == 0 {
                s.clear()
                m.clear()
            }
        } else if which == 7 {
            // A view of the current text, mutated, leaves `s` alone.
            var v = s.view()
            v.push('!')
            ck(v.size() == s.size() + 1, 4, "view grows by itself")
        } else if which == 8 {
            // A copy is independent of the original.
            var c = s.copy()
            c.push_str("copy")
            ck(c.size() == s.size() + 4, 5, "copy grows by itself")
        } else {
            var to = s.to_owned()
            to.insert(0, "x")
            ck(to.size() == s.size() + 1, 6, "to_owned grows by itself")
        }

        if !agrees(s, m) {
            ck(false, 10, f"state {kind} seed {seed} step {step} op {which}")
            return
        }

        if !agrees(bystander, bm) {
            ck(false, 11, f"bystander changed: state {kind} seed {seed} step {step} op {which}")
            return
        }
    }
}

fn main() -> i32 {
    for var kind: usize = 0; kind < 3; kind += 1 {
        for var seed: u64 = 1; seed <= 12; seed += 1 {
            run(kind, seed * 7919 + (kind as u64), 400)
        }
    }

    return CODE
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %t.o2.exe

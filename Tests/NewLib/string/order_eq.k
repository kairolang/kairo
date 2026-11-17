// `<=>`, `<` and `==` of strings against a byte-by-byte comparison. A seeded
// xorshift stream builds pairs that share a prefix of every length up to
// five words and then differ, or stop, at every distance from a word
// boundary; the chars are of every UTF-8 width, so a byte above 0x7f must
// order above ASCII (bytes compare unsigned) and a proper prefix must order
// first. Each pair is compared as two heap strings, as views cut from longer
// text at every alignment, and with the sides swapped.
import std::io

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

    pub fn below(self, n: u64) -> usize {
        return (((self.next() >> 32) * n) >> 32) as usize
    }

    // One, two, three and four byte chars; ASCII half the time.
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

// -1, 0 or 1 by bytes, unsigned, a proper prefix first.
fn naive(const a: string, const b: string) -> i32 {
    var x = a.bytes()
    var y = b.bytes()
    var n = x.size()
    if y.size() < n {
        n = y.size()
    }

    for var i: usize = 0; i < n; i += 1 {
        if x[i] != y[i] {
            return if x[i] < y[i] => -1 else => 1
        }
    }

    if x.size() == y.size() {
        return 0
    }

    return if x.size() < y.size() => -1 else => 1
}

fn got(const a: string, const b: string) -> i32 {
    var o = a <=> b
    if o == Ordering::Less {
        return -1
    }

    if o == Ordering::Greater {
        return 1
    }

    return 0
}

// The number of disagreements between the operators and `want`.
fn check(const a: string, const b: string, want: i32) -> usize {
    var bad: usize = 0
    if got(a, b) != want {
        bad += 1
    }

    if got(b, a) != -want {
        bad += 1
    }

    if (a < b) != (want < 0) {
        bad += 1
    }

    if (b < a) != (want > 0) {
        bad += 1
    }

    if (a == b) != (want == 0) {
        bad += 1
    }

    if (b == a) != (want == 0) {
        bad += 1
    }

    return bad
}

fn main() -> i32 {
    var bad:   usize = 0
    var pairs: usize = 0
    var kinds: [usize; 3] = [0, 0, 0]
    for var seed: u64 = 1; seed <= 4; seed += 1 {
        var rng = Rng(seed * 0x9E3779B97F4A7C15)
        for var step = 0; step < 40000; step += 1 {
            // A shared prefix, then two tails, either of which may be empty.
            var shared = rng.below(44)
            var a      = string()
            var b      = string()
            while a.size() < shared {
                var c = rng.scalar()
                a.push(c)
                b.push(c)
            }

            var ta = rng.below(12)
            var tb = rng.below(12)
            if rng.below(4) == 0 {
                ta = 0
            }

            if rng.below(4) == 0 {
                tb = 0
            }

            for var i: usize = 0; i < ta; i += 1 {
                a.push(rng.scalar())
            }

            for var i: usize = 0; i < tb; i += 1 {
                b.push(rng.scalar())
            }

            var want = naive(a, b)
            kinds[(want + 1) as usize] += 1
            bad += check(a, b, want)
            // The same two texts as views at every alignment of their
            // first byte, each inside longer text.
            var pad = rng.below(9)
            var la  = string()
            var lb  = string()
            for var i: usize = 0; i < pad; i += 1 {
                la.push('x')
            }

            for var i: usize = 0; i < 8 - pad; i += 1 {
                lb.push('y')
            }

            la += a
            lb += b
            la.push('!')
            lb.push('?')
            var va = la[pad..(pad + a.size())]
            var vb = lb[(8 - pad)..(8 - pad + b.size())]
            bad += check(va, vb, want)
            bad += check(va, b, want)
            bad += check(a, vb, want)
            // A copy is equal to its source in every state.
            var ca = va.to_owned()
            bad += check(ca, a, 0)
            bad += check(ca, va, 0)
            if ca.codepoints() != a.codepoints() || ca.is_ascii() != a.is_ascii() {
                bad += 1
            }

            pairs += 1
        }
    }

    if bad != 0 {
        io::println(f"FAIL {bad}")
        return 1
    }

    if kinds[0] < 1000 || kinds[1] < 1000 || kinds[2] < 1000 {
        io::println("FAIL spread")
        return 1
    }

    io::println(f"ok {pairs}")
    return 0
}

// CHECK: ok 160000

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s

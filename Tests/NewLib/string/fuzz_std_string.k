// Differential fuzz of string against C++ std::string. A seeded xorshift
// stream picks operations; each is applied to a Kairo string and to a
// std::string, and after every step the bytes, the length, the codepoint
// count (against a count over the std::string's bytes), the ASCII answer
// and the terminator are compared. The text is valid UTF-8 built from
// random scalar values of every width, and byte offsets are drawn from the
// whole range, so they land on and off char boundaries: an offset the
// bytes say is not a boundary would trap (traps.k proves that), so that
// operation is skipped on both sides after checking that is_char_boundary
// agrees with the bytes.
//
// With no argument the run is 4 seeds of 50000 steps. Each extra argument
// multiplies the steps per seed by ten. A failure prints the seed and step.

ffi "c++" import "string"
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

    // Uniform in [0, n) for n < 2^32.
    pub fn below(self, n: u64) -> usize {
        return (((self.next() >> 32) * n) >> 32) as usize
    }

    // A scalar value: ASCII six times in ten, the wider forms otherwise.
    pub fn scalar(self) -> char {
        var k      = self.below(20)
        var v: u32 = 0
        if k < 12 {
            v = 32 + (self.below(95) as u32)
        } else if k < 15 {
            v = 0x80 + (self.below(0x780) as u32)
        } else if k < 18 {
            v = 0x800 + (self.below(0xf800) as u32)
            if v >= 0xd800 && v < 0xe000 {
                v = 0x20ac
            }
        } else {
            v = 0x10000 + (self.below(0x100000) as u32)
        }

        var c: char = v
        return c
    }

    // Up to `max` random chars.
    pub fn text(self, max: u64) -> string {
        var s = string()
        var n = self.below(max + 1)
        for var i: usize = 0; i < n; i += 1 {
            s.push(self.scalar())
        }

        return s
    }
}

fn cptr(const s: string) -> unsafe *const __builtin_c_char {
    unsafe {
        return s.data() as unsafe *const u8 as unsafe *const __builtin_c_char
    }
}

// Byte `i` of the std::string.
fn cb(const c: cxx::std::string, i: usize) -> u8 {
    unsafe {
        return (c.data() as unsafe *const u8)[i]
    }
}

// Whether offset `b` of the std::string's bytes starts a char or is the end.
fn c_boundary(const c: cxx::std::string, b: usize) -> bool {
    if b >= c.size() {
        return b == c.size()
    }

    return (cb(c, b) & 0xc0) != 0x80
}

fn c_codepoints(const c: cxx::std::string) -> usize {
    var n: usize = 0
    for var i: usize = 0; i < c.size(); i += 1 {
        if (cb(c, i) & 0xc0) != 0x80 {
            n += 1
        }
    }

    return n
}

// The whole state of `k` against `c`.
fn same(const k: string, const c: cxx::std::string) -> bool {
    var n = c.size()
    if k.size() != n {
        return false
    }

    unsafe {
        var unsafe *kp = k.data() as unsafe *const u8
        var unsafe *cp = c.data() as unsafe *const u8
        for var i: usize = 0; i < n; i += 1 {
            if kp[i] != cp[i] {
                return false
            }
        }

        // An owned or literal string is terminated.
        if !k.is_view() && kp[n] != 0 {
            return false
        }
    }

    var cps = c_codepoints(c)
    if k.codepoints() != cps || k.is_ascii() != (cps == n) || k.is_empty() != (n == 0) {
        return false
    }

    if k.is_owned() && k.capacity() < n {
        return false
    }

    return true
}

// A boundary of `c` at or below a random offset.
fn pick_boundary(rng: *Rng, const c: cxx::std::string) -> usize {
    var b = rng->below(c.size() as u64 + 1)
    while !c_boundary(c, b) {
        b -= 1
    }

    return b
}

fn run(seed: u64, steps: u64) -> bool {
    var rng     = Rng(seed)
    var k       = string()
    var c       = cxx::std::string()
    var skipped: u64 = 0
    var longest: usize = 0
    var total:   u64   = 0

    for var step: u64 = 0; step < steps; step += 1 {
        var kind = rng.below(20)
        var len  = c.size()

        // Now and then the text is emptied, cut short or replaced; past 600
        // bytes it always is, so every offset keeps being drawn often.
        if rng.below(120) == 0 {
            kind = 20 + rng.below(4)
        }

        if len > 600 {
            kind = 20 + rng.below(2)
        }

        if kind <= 2 {
            var ch = rng.scalar()
            var one = string(ch, 1)
            k.push(ch)
            c.append(cptr(one), one.size())
        } else if kind <= 4 {
            var piece = rng.text(12)
            if rng.below(2) == 0 {
                k.push_str(piece)
            } else {
                k += piece.view()
            }

            c.append(cptr(piece), piece.size())
        } else if kind == 5 {
            // Self-append: the whole string, by name or through a view.
            if len <= 300 {
                var copy = cxx::std::string(c)
                if rng.below(2) == 0 {
                    k += k.view()
                } else {
                    k.push_str(k)
                }

                c.append(copy)
            }
        } else if kind == 6 {
            // Self-append of a part.
            var lo = pick_boundary(&rng, c)
            var hi = pick_boundary(&rng, c)
            if lo > hi {
                var t = lo
                lo = hi
                hi = t
            }

            var part = cxx::std::string(c, lo, hi - lo)
            k += k[lo..hi]
            c.append(part)
        } else if kind <= 9 {
            // insert at any offset, two past the end included.
            var at    = rng.below(len as u64 + 3)
            var piece = rng.text(6)
            var ok    = at <= len && c_boundary(c, at)
            if k.is_char_boundary(at) != ok {
                io::println(f"boundary disagrees: seed {seed} step {step} at {at}")
                return false
            }

            if ok {
                if kind == 9 && len > 0 {
                    // The inserted text is a view of the string itself.
                    var lo = pick_boundary(&rng, c)
                    var hi = pick_boundary(&rng, c)
                    if lo > hi {
                        var t = lo
                        lo = hi
                        hi = t
                    }

                    var part = cxx::std::string(c, lo, hi - lo)
                    k.insert(at, k[lo..hi])
                    c.insert(at, part)
                } else {
                    k.insert(at, piece)
                    c.insert(at, cptr(piece), piece.size())
                }
            } else {
                skipped += 1
            }
        } else if kind <= 12 {
            // remove_range between any two offsets.
            var lo = rng.below(len as u64 + 2)
            var hi = rng.below(len as u64 + 2)
            if lo > hi {
                var t = lo
                lo = hi
                hi = t
            }

            if hi <= len && c_boundary(c, lo) && c_boundary(c, hi) {
                k.remove_range(lo..hi)
                c.erase(lo, hi - lo)
            } else {
                skipped += 1
            }
        } else if kind == 13 {
            // truncate at any offset.
            var at = rng.below(len as u64 + 3)
            if at >= len {
                k.truncate(at)
            } else if c_boundary(c, at) {
                k.truncate(at)
                c.resize(at)
            } else {
                skipped += 1
            }
        } else if kind == 14 {
            // pop: the char the bytes end with.
            var got? = k.pop()
            if len == 0 {
                if got? {
                    io::println(f"pop of empty: seed {seed} step {step}")
                    return false
                }
            } else {
                var at = len - 1
                while !c_boundary(c, at) {
                    at -= 1
                }

                // The last char, decoded from the std::string's bytes.
                var want: char = 0
                unsafe {
                    var tail? = string::from_utf8(
                        Slice<const u8>((c.data() as unsafe *const u8) + at, len - at),
                    )

                    if tail? {
                        want = tail.first() ?? want
                    }
                }

                c.resize(at)
                if !(got === want) {
                    io::println(f"pop differs: seed {seed} step {step}")
                    return false
                }
            }
        } else if kind == 15 {
            // find and rfind of a piece cut from the text, and of a random one.
            var lo = pick_boundary(&rng, c)
            var hi = pick_boundary(&rng, c)
            if lo > hi {
                var t = lo
                lo = hi
                hi = t
            }

            var needle = k[lo..hi].to_owned()
            if rng.below(3) == 0 {
                needle = rng.text(3)
            }

            var cn = cxx::std::string(cptr(needle), needle.size())
            var kf = k.find(needle) ?? usize::MAX
            var kr = k.rfind(needle) ?? usize::MAX
            if kf != c.find(cn) || kr != c.rfind(cn) {
                io::println(f"find differs: seed {seed} step {step}")
                return false
            }
        } else if kind == 16 {
            // copy and to_owned are equal and independent.
            var a = k.copy()
            var b = k.to_owned()
            if !same(a, c) || !same(b, c) || !(a == k) || (len > 0 && !b.is_owned()) {
                io::println(f"copy differs: seed {seed} step {step}")
                return false
            }

            if rng.below(2) == 0 {
                k = b
            }
        } else if kind == 17 {
            // A view, then a write through it: the view is promoted, the source is not touched.
            var v = k.view()
            if !same(v, c) {
                io::println(f"view differs: seed {seed} step {step}")
                return false
            }

            var ch  = rng.scalar()
            var one = string(ch, 1)
            v.push(ch)
            if !same(k, c) || !v.is_owned() || v.size() != len + one.size() || !v.ends_with(one) {
                io::println(f"promoted view differs: seed {seed} step {step}")
                return false
            }

            if rng.below(2) == 0 {
                k = v
                c.append(cptr(one), one.size())
            }
        } else if kind == 18 {
            // c_str of the string and of a view of a part.
            unsafe {
                var unsafe *z = k.c_str() as unsafe *const u8
                var unsafe *w = c.c_str() as unsafe *const u8
                for var i: usize = 0; i <= len; i += 1 {
                    if z[i] != w[i] {
                        io::println(f"c_str differs: seed {seed} step {step}")
                        return false
                    }
                }
            }

            var lo = pick_boundary(&rng, c)
            var v  = k[lo..]
            var cv = cxx::std::string(c, lo, len - lo)
            unsafe {
                var unsafe *z = v.c_str() as unsafe *const u8
                if !same(v, cv) || (!v.is_empty() && v.is_view()) || z[len - lo] != 0 {
                    io::println(f"c_str of a view differs: seed {seed} step {step}")
                    return false
                }
            }
        } else if kind == 19 {
            // Capacity changes leave the text alone; a std::string converts as it is.
            if rng.below(2) == 0 {
                k.reserve(rng.below(900))
            } else {
                k.shrink_to_fit()
            }

            var back = string(c)
            if !same(back, c) || !(back == k) {
                io::println(f"conversion differs: seed {seed} step {step}")
                return false
            }
        } else if kind == 20 {
            k.clear()
            c.clear()
        } else if kind == 21 {
            // Back to a boundary at or below 40 bytes.
            var at = pick_boundary(&rng, c)
            while at > 40 || !c_boundary(c, at) {
                at -= 1
            }

            k.truncate(at)
            c.resize(at)
        } else {
            // A fresh string in another state takes the place of the old one.
            var piece = rng.text(20)
            c.assign(cptr(piece), piece.size())
            if kind == 22 {
                k = piece
            } else {
                k = piece.view().copy().to_owned()
                k.shrink_to_fit()
            }
        }

        if !same(k, c) {
            io::println(f"state differs: seed {seed} step {step} kind {kind}")
            return false
        }

        total += c.size() as u64
        if c.size() > longest {
            longest = c.size()
        }
    }

    // Offsets off a boundary were drawn, and the text grew past a few
    // reallocations: a run without either checks little.
    if steps >= 10000 && (skipped == 0 || longest < 300) {
        io::println(f"weak run: seed {seed}, {skipped} skipped, longest {longest}")
        return false
    }

    io::println(f"seed {seed}: {skipped} offsets off a boundary, longest text {longest}, mean {total / steps}")
    return true
}

fn main(argc: i32) -> i32 {
    var steps: u64 = 50000
    for var i = 1; i < argc; i += 1 {
        steps *= 10
    }

    var seeds: [u64; 4] = [0x9e3779b97f4a7c15, 0x243f6a8885a308d3, 0xb7e151628aed2a6b, 0x452821e638d01377]
    for var i: usize = 0; i < 4; i += 1 {
        if !run(seeds[i], steps) {
            return 1
        }
    }

    io::println(f"ok {steps * 4}")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// RUN: %t.o2.exe more | %FileCheck %s --check-prefix=MORE
// CHECK: ok 200000
// MORE:  ok 2000000

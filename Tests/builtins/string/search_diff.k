// Substring and char search against a search that compares at every
// position: random haystacks over {a, b, c} (b and c differ in one bit) at
// every alignment of a view, with needles of 0 to 40 bytes, from every kind
// of start; and haystacks built to defeat the first-and-last-byte filter,
// where the search must stay linear and still be right.

import std::io

static FAILS: i32 = 0

fn fail(const what: string) {
    if FAILS < 20 {
        io::println(what)
    }

    FAILS += 1
}

class Rng {
    var s: u64

    pub fn Rng(self, seed: u64) {
        self.s = seed
    }

    pub fn below(self, n: u64) -> usize {
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return (((self.s >> 32) * n) >> 32) as usize
    }

    pub fn letters(self, n: usize, alphabet: u64) -> string {
        var s = string::with_capacity(n)
        for var i: usize = 0; i < n; i += 1 {
            var c: char = 97 + (self.below(alphabet) as u32)
            s.push(c)
        }

        return s
    }
}

fn match_at(const h: [const u8;], const n: [const u8;], i: usize) -> bool {
    for var j: usize = 0; j < n.size(); j += 1 {
        if h[i + j] != n[j] {
            return false
        }
    }

    return true
}

// First match at or after `from`, or NO_MATCH.
fn naive_find(const h: string, const n: string, from: usize) -> usize {
    var hb = h.bytes()
    var nb = n.bytes()
    if nb.size() > hb.size() {
        return NO_MATCH
    }

    for var i = from; i + nb.size() <= hb.size(); i += 1 {
        if match_at(hb, nb, i) {
            return i
        }
    }

    return NO_MATCH
}

// Last match ending at or before `to`, or NO_MATCH.
fn naive_rfind(const h: string, const n: string, to: usize) -> usize {
    var hb  = h.bytes()
    var nb  = n.bytes()
    var lim = to
    if lim > hb.size() {
        lim = hb.size()
    }

    if nb.size() > lim {
        return NO_MATCH
    }

    var i = lim - nb.size()
    loop {
        if match_at(hb, nb, i) {
            return i
        }

        if i == 0 {
            break
        }

        i -= 1
    }

    return NO_MATCH
}

fn check(const h: string, const n: string, from: usize, const what: string) {
    var f = n.find_in(h, from)
    var w = naive_find(h, n, from)
    if f.0 != w || (w != NO_MATCH && f.1 != n.size()) {
        fail(f"find {what}: got {f.0}, want {w}")
    }

    var r  = n.rfind_in(h, from)
    var wr = naive_rfind(h, n, from)
    if r.0 != wr || (wr != NO_MATCH && r.1 != n.size()) {
        fail(f"rfind {what}: got {r.0}, want {wr}")
    }
}

fn random_cases(cases: usize) {
    var rng = Rng(0x5eed5eed)
    for var k: usize = 0; k < cases; k += 1 {
        var text = rng.letters(rng.below(120), 3)
        var lo   = rng.below(text.size() as u64 + 1)
        var hay  = text[lo..]
        // A needle cut from the haystack hits; a random one mostly misses.
        var nlen   = rng.below(9)
        if rng.below(8) == 0 {
            nlen = rng.below(41)
        }

        var needle = rng.letters(nlen, 3)
        if hay.size() > 0 && rng.below(2) == 0 {
            var a = rng.below(hay.size() as u64)
            var b = a + rng.below(9)
            if b > hay.size() {
                b = hay.size()
            }

            needle = hay[a..b].to_owned()
        }

        var from = rng.below(hay.size() as u64 + 3)
        check(hay, needle, from, "random case")
        if FAILS != 0 {
            io::println(f"case {k}")
            return
        }

        // One char: the byte search.
        if needle.size() > 0 {
            var c    = needle[0]
            var one  = needle[..1]
            var cf   = c.find_in(hay, from).0
            var cr   = c.rfind_in(hay, from).0
            var want = naive_find(hay, one, from)
            if cf != want {
                fail(f"char find, case {k}")
            }

            want = naive_rfind(hay, one, from)
            if cr != want {
                fail(f"char rfind, case {k}")
            }
        }
    }
}

// Haystacks where the first and the last byte of the needle match almost
// everywhere and the middle fails late.
fn adversarial() {
    var all_a = string('a', 6000)
    for var mid: usize = 1; mid <= 3; mid += 1 {
        for var half: usize = 20; half <= 320; half *= 4 {
            // a^half, `mid` b's, a^half.
            var needle = string('a', half)
            needle += string('b', mid)
            needle += string('a', half)
            check(all_a, needle, 0, "all a, absent")
            check(all_a, needle, 6000, "all a, absent, from the end")

            var with = all_a.concat(needle)
            var end  = with.size()
            check(with, needle, 0, "all a, at the end")
            check(with, needle, end, "all a, at the end, backward")
            var front = needle.concat(all_a)
            check(front, needle, 0, "all a, at the start")
            check(front, needle, end, "all a, at the start, backward")
            check(front, needle, 1, "all a, past the only match")
        }
    }

    // A periodic needle in a periodic haystack that breaks the period once.
    var unit  = "abcab"
    var hay   = unit.repeat(900)
    var probe = unit.repeat(40)
    check(hay, probe, 0, "periodic hit")
    check(hay, probe, 4495, "periodic, from near the end")
    var broken = unit.repeat(20).concat("x").concat(unit.repeat(20))
    check(hay, broken, 0, "periodic miss")
    var planted = unit.repeat(400).concat(broken).concat(unit.repeat(400))
    var planted_end = planted.size()
    check(planted, broken, 0, "periodic, planted")
    check(planted, broken, planted_end, "periodic, planted, backward")

    // Needle as long as the haystack, and one byte longer.
    check(probe, probe, 0, "whole haystack")
    var longer = probe.concat("a")
    check(probe, longer, 0, "needle longer than the haystack")
}

fn main(argc: i32) -> i32 {
    var cases: usize = 60000
    if argc > 1 {
        cases = 2000000
    }

    random_cases(cases)
    adversarial()
    if FAILS == 0 {
        io::println("ok")
    }

    return FAILS
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe more | %FileCheck %s --match-full-lines
// CHECK: ok

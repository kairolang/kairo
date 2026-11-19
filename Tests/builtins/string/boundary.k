// Char boundaries at every byte offset of text that mixes 1, 2, 3 and 4
// byte chars, in each state: is_char_boundary and get agree with the bytes,
// and slicing, insert, remove_range and truncate at every boundary give the
// text a byte-wise model gives. An ASCII string has a boundary everywhere.

import std::io

static FAILS: i32 = 0

fn ck(ok: bool, id: i32) {
    if !ok {
        io::println(f"FAIL {id}")
        FAILS += 1
    }
}

// Whether byte offset `b` starts a char or is the end, read off the bytes.
fn naive_boundary(const s: string, b: usize) -> bool {
    var by = s.bytes()
    if b >= by.size() {
        return b == by.size()
    }

    return (by[b] & 0xc0) != 0x80
}

fn naive_cps(const s: string) -> usize {
    var by       = s.bytes()
    var n: usize = 0
    for var i: usize = 0; i < by.size(); i += 1 {
        if (by[i] & 0xc0) != 0x80 {
            n += 1
        }
    }

    return n
}

// `src` in state `kind`: 0 as it is (a literal), 1 a view, 2 a heap string.
fn mk(kind: i32, const src: string) -> string {
    if kind == 0 {
        return src.copy()
    }

    if kind == 1 {
        return src.view()
    }

    return src.to_owned()
}

fn main() -> i32 {
    var text = "aé€😀zé😀€b" // 1 2 3 4 1 2 4 3 1
    var n    = text.size()
    ck(n == 21, 1)

    for var k = 0; k < 3; k += 1 {
        var base = 1000 * (k + 1)
        var s    = mk(k, text)
        var bad  = 0

        // The predicate and get at every offset, and two past the end.
        for var b: usize = 0; b <= n + 2; b += 1 {
            var want = naive_boundary(text, b)
            if s.is_char_boundary(b) != want {
                bad += 1
            }

            var g? = s.get(b)
            if g? != (want && b < n) {
                bad += 1
            }

            if want && b < n {
                if !(s.get(b) === s[b]) {
                    bad += 1
                }
            }
        }

        ck(bad == 0, base + 1)

        // Every slice between two boundaries: the bytes, the count, a view.
        bad = 0
        for var lo: usize = 0; lo <= n; lo += 1 {
            if !naive_boundary(text, lo) {
                continue
            }

            for var hi = lo; hi <= n; hi += 1 {
                if !naive_boundary(text, hi) {
                    continue
                }

                var v  = s[lo..hi]
                var by = text.bytes()
                if v.size() != hi - lo || !v.is_view() || v.codepoints() != naive_cps(v) {
                    bad += 1
                }

                for var i: usize = 0; i < v.size(); i += 1 {
                    if v.bytes()[i] != by[lo + i] {
                        bad += 1
                    }
                }

                if hi > lo && !(s[lo..=(hi - 1)] == v) {
                    bad += 1
                }
            }

            if !(s[lo..] == s[lo..n]) || !(s[..lo] == s[0..lo]) {
                bad += 1
            }
        }

        ck(bad == 0, base + 2)

        // insert, remove_range and truncate at every boundary, against the
        // text put together from slices.
        bad = 0
        for var lo: usize = 0; lo <= n; lo += 1 {
            if !naive_boundary(text, lo) {
                continue
            }

            var ins = mk(k, text)
            ins.insert(lo, "é-")
            var want = text[..lo].concat("é-").concat(text[lo..])
            if !(ins == want) || ins.codepoints() != naive_cps(want) || !ins.is_owned() {
                bad += 1
            }

            var tr = mk(k, text)
            tr.truncate(lo)
            var head = text[..lo]
            if !(tr == head) || tr.codepoints() != naive_cps(tr) {
                bad += 1
            }

            for var hi = lo; hi <= n; hi += 1 {
                if !naive_boundary(text, hi) {
                    continue
                }

                var rm = mk(k, text)
                rm.remove_range(lo..hi)
                var left = text[..lo].concat(text[hi..])
                if !(rm == left) || rm.codepoints() != naive_cps(left) {
                    bad += 1
                }

                if rm.is_ascii() != (naive_cps(left) == left.size()) && rm.is_owned() {
                    bad += 1
                }
            }
        }

        ck(bad == 0, base + 3)
    }

    // ASCII: every offset up to the length is a boundary, in every state.
    var ascii = "hello, world"
    for var k = 0; k < 3; k += 1 {
        var s   = mk(k, ascii)
        var bad = 0
        for var b: usize = 0; b <= ascii.size() + 1; b += 1 {
            if s.is_char_boundary(b) != (b <= ascii.size()) {
                bad += 1
            }
        }

        ck(bad == 0, 5000 + k)
    }

    // A view cut from non-ASCII text carries no ASCII bit, yet its
    // boundaries are still read off its bytes.
    var cut = text[1..6]
    ck(cut.is_char_boundary(0) && !cut.is_char_boundary(1) && cut.is_char_boundary(2), 6000)
    ck(!cut.is_char_boundary(3) && !cut.is_char_boundary(4) && cut.is_char_boundary(5) && !cut.is_char_boundary(6), 6001)

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
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: ok

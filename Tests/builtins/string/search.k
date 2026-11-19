// Searching with the three patterns (a string, a char, a predicate):
// needles at the start, at the end, absent, overlapping, empty and longer
// than the haystack; forward and backward; on a literal, a view and a heap
// string; and the answers a hand-written loop gives for the same question.

import std::io

static FAILS: i32 = 0

fn ck(ok: bool, id: i32) {
    if !ok {
        io::println(f"FAIL {id}")
        FAILS += 1
    }
}

fn ch(v: u32) -> char {
    var c: char = v
    return c
}

fn is_digit(c: char) -> bool {
    return c >= '0' && c <= '9'
}

fn is_wide(c: char) -> bool {
    return (c as u32) >= 0x80
}

fn never(c: char) -> bool {
    return false
}

// The first index at or after `from` where `n` occurs in `h`, by comparing
// at every position.
fn naive_find(const h: string, const n: string, from: usize) -> usize {
    var hb = h.bytes()
    var nb = n.bytes()
    if nb.size() > hb.size() {
        return NO_MATCH
    }

    for var i = from; i + nb.size() <= hb.size(); i += 1 {
        var same = true
        for var j: usize = 0; j < nb.size(); j += 1 {
            if hb[i + j] != nb[j] {
                same = false
                break
            }
        }

        if same {
            return i
        }
    }

    return NO_MATCH
}

fn at(r: usize?) -> usize {
    return r ?? NO_MATCH
}

fn main() -> i32 {
    var hay = "abcabcabd"

    // A string needle.
    ck(at(hay.find("abc")) == 0, 1)
    ck(at(hay.find("abd")) == 6, 2)
    ck(at(hay.find("bca")) == 1, 3)
    ck(at(hay.find("x")) == NO_MATCH, 4)
    ck(at(hay.find("abcabcabdx")) == NO_MATCH, 5)
    ck(at(hay.find("")) == 0, 6)
    ck(at(hay.find(hay)) == 0, 7)
    ck(at(hay.rfind("abc")) == 3, 8)
    ck(at(hay.rfind("ab")) == 6, 9)
    ck(at(hay.rfind("x")) == NO_MATCH, 10)
    ck(at(hay.rfind("")) == 9, 11)
    ck(at("".find("")) == 0 && at("".rfind("")) == 0, 12)
    ck(at("".find("a")) == NO_MATCH && at("".rfind("a")) == NO_MATCH, 13)
    // Overlapping occurrences: the first and the last.
    ck(at("aaaa".find("aa")) == 0 && at("aaaa".rfind("aa")) == 2, 14)

    // The same answers whatever the state of either side.
    var hv = hay.view()
    var hh = hay.to_owned()
    var nh = "abd".to_owned()
    ck(at(hv.find("abd")) == 6 && at(hh.find("abd")) == 6, 20)
    ck(at(hay.find(nh)) == 6 && at(hv.find(nh.view())) == 6, 21)

    // A char needle: ASCII and wider.
    var mixed = "aé€😀zé"
    ck(at(mixed.find('a')) == 0 && at(mixed.find('z')) == 10, 30)
    ck(at(mixed.find(ch(0xe9))) == 1 && at(mixed.rfind(ch(0xe9))) == 11, 31)
    ck(at(mixed.find(ch(0x20ac))) == 3 && at(mixed.find(ch(0x1f600))) == 6, 32)
    ck(at(mixed.find('q')) == NO_MATCH && at(mixed.rfind(ch(0xe8))) == NO_MATCH, 33)
    ck(at("".find('a')) == NO_MATCH, 34)

    // A predicate.
    var text = "ab12é3"
    ck(at(text.find(Pred { f: is_digit })) == 2, 40)
    ck(at(text.rfind(Pred { f: is_digit })) == 6, 41)
    ck(at(text.find(Pred { f: is_wide })) == 4, 42)
    ck(at(text.find(Pred { f: never })) == NO_MATCH, 43)
    ck(at(text.rfind(Pred { f: never })) == NO_MATCH, 44)

    // contains and `in`.
    ck(hay.contains("cab") && !hay.contains("cba") && hay.contains(""), 50)
    ck(hay.contains('d') && !hay.contains('e'), 51)
    ck(text.contains(Pred { f: is_digit }) && !hay.contains(Pred { f: is_digit }), 52)
    ck("cab" in hay, 53)
    ck('d' in hay, 54)
    ck(!("xyz" in hay), 55)

    // starts_with / ends_with.
    ck(hay.starts_with("abc") && !hay.starts_with("bc") && hay.starts_with(""), 60)
    ck(hay.starts_with(hay) && !hay.starts_with("abcabcabdx"), 61)
    ck(hay.ends_with("abd") && !hay.ends_with("abc") && hay.ends_with(""), 62)
    ck(hay.starts_with('a') && !hay.starts_with('b') && hay.ends_with('d') && !hay.ends_with('a'), 63)
    ck(mixed.starts_with('a') && mixed.ends_with(ch(0xe9)) && !mixed.ends_with('z'), 64)
    ck(text.starts_with(Pred { f: never }) == false && text.ends_with(Pred { f: is_digit }), 65)
    ck("1x".starts_with(Pred { f: is_digit }) && !"x1".starts_with(Pred { f: is_digit }), 66)
    ck(!"".starts_with('a') && !"".ends_with('a') && "".starts_with("") && "".ends_with(""), 67)

    // count: matches that do not overlap.
    ck(hay.count("abc") == 2 && hay.count("ab") == 3 && hay.count("x") == 0, 70)
    ck("aaaa".count("aa") == 2 && "aaaaa".count("aa") == 2, 71)
    ck(hay.count('a') == 3 && mixed.count(ch(0xe9)) == 2, 72)
    ck(text.count(Pred { f: is_digit }) == 3, 73)
    // An empty pattern matches before every char and at the end.
    ck("abc".count("") == 4 && "é€".count("") == 3 && "".count("") == 1, 74)

    // Against the naive search: every needle of 1 to 4 bytes over {a, b}
    // in a haystack that crosses several words, from every start.
    var big = "abbabaabbaababbabaababbaabbabaabababbabbaabaabbab"
    var bad = 0
    for var len: usize = 1; len <= 4; len += 1 {
        for var code: usize = 0; code < (1usize << len); code += 1 {
            var n = string()
            for var k: usize = 0; k < len; k += 1 {
                if ((code >> k) & 1) == 0 {
                    n.push('a')
                } else {
                    n.push('b')
                }
            }

            for var from: usize = 0; from <= big.size(); from += 1 {
                var want = naive_find(big, n, from)
                var got  = n.find_in(big, from).0
                if got != want {
                    bad += 1
                }

                var sub = big[from..]
                var w2  = naive_find(sub, n, 0)
                if at(sub.find(n)) != w2 {
                    bad += 1
                }
            }
        }
    }

    ck(bad == 0, 80)

    // A long needle whose first and last byte match everywhere and whose
    // middle fails late: the search stays linear and still finds the end.
    var worst = string('a', 20000)
    var needle = string('a', 300)
    needle.push('b')
    needle += string('a', 50)
    ck(at(worst.find(needle)) == NO_MATCH && at(worst.rfind(needle)) == NO_MATCH, 90)
    worst += needle
    ck(at(worst.find(needle)) == 20000 && at(worst.rfind(needle)) == 20000, 91)

    // Pattern ranges: start and length, and where the search resumes.
    var r = "é".find_in(mixed, 0)
    ck(r.0 == 1 && r.1 == 2, 100)
    r = "é".find_in(mixed, 2)
    ck(r.0 == 11 && r.1 == 2, 101)
    r = "é".find_in(mixed, 12)
    ck(r.0 == NO_MATCH, 102)
    r = "é".rfind_in(mixed, 12)
    ck(r.0 == 1 && r.1 == 2, 103)
    r = "é".rfind_in(mixed, 2)
    ck(r.0 == NO_MATCH, 104)
    r = "".find_in(mixed, 99)
    ck(r.0 == NO_MATCH, 105)

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

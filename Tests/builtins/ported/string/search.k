// Searching: find, rfind, contains, `in`, starts_with, ends_with, count,
// strip_prefix, strip_suffix, split_once, rsplit_once and trim_matches with
// the three patterns (a string, a char, a predicate); needles at the start,
// in the middle, at the end, absent, overlapping, empty and longer than the
// haystack; multi-byte needles and haystacks; a search that starts or ends in
// a sub-range of the text is spelled with a range (`s[from..].find(p)`).
// Results are byte offsets.
// Cases from libc++ test/std/strings/basic.string/string.ops/string_find/
// Cases from libc++ test/std/strings/basic.string/string.ops/string_starts.with/
// Cases from libc++ test/std/strings/basic.string/string.ops/string.contains/
// Cases from Rust library/alloctests/tests/str.rs (find, rfind, contains, starts_with, strip_prefix, matches)

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

fn is_digit(c: char) -> bool {
    return c >= '0' && c <= '9'
}

fn is_wide(c: char) -> bool {
    return (c as u32) >= 0x80
}

fn never(c: char) -> bool {
    return false
}

fn always(c: char) -> bool {
    return true
}

fn mk(kind: i32, const src: string) -> string {
    if kind == 0 {
        return src.copy()
    }

    if kind == 1 {
        return src.view()
    }

    return src.to_owned()
}

// The offset of a match, or -1 for none.
fn at(r: usize?) -> isize {
    var v: usize = r ?? NO_MATCH
    if v == NO_MATCH {
        return -1
    }

    return v as isize
}

fn find_string() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var h = mk(k, "abcabcabc")
        ck(at(h.find("abc")) == 0, b + 1, "find at the start")
        ck(at(h.find("bca")) == 1, b + 2, "find in the middle")
        ck(at(h.find("cabc")) == 2, b + 3, "find overlapping the first")
        ck(at(h.find("c")) == 2, b + 4, "find one byte")
        ck(at(h.find("abcabcabc")) == 0, b + 5, "find the whole text")
        ck(at(h.find("abcabcabcd")) == -1, b + 6, "find longer than the text")
        ck(at(h.find("x")) == -1, b + 7, "find absent")
        ck(at(h.find("")) == 0, b + 8, "find empty is 0")
        ck(at(h.find("cba")) == -1, b + 9, "find a permutation")
        var e = mk(k, "")
        ck(at(e.find("")) == 0, b + 10, "find empty in empty")
        ck(at(e.find("a")) == -1, b + 11, "find in empty")
        ck(at(h[3..].find("abc")) == 0 && at(h[1..].find("abc")) == 2, b + 12, "find from an offset")
        ck(at(h[7..].find("abc")) == -1 && at(h[9..].find("")) == 0, b + 13, "find from near the end")
        var t = mk(k, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxy")
        ck(at(t.find("xxy")) == 46 && at(t.find("xyx")) == -1, b + 14, "find in a long run")
        var d = mk(k, "aaab")
        ck(at(d.find("aab")) == 1 && at(d.find("aaa")) == 0, b + 15, "find after a partial match")
    }
}

fn rfind_string() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var h = mk(k, "abcabcabc")
        ck(at(h.rfind("abc")) == 6, b + 1, "rfind the last")
        ck(at(h.rfind("bca")) == 4, b + 2, "rfind in the middle")
        ck(at(h.rfind("c")) == 8, b + 3, "rfind one byte")
        ck(at(h.rfind("a")) == 6, b + 4, "rfind a")
        ck(at(h.rfind("x")) == -1, b + 5, "rfind absent")
        ck(at(h.rfind("")) == 9, b + 6, "rfind empty is the size")
        ck(at(h.rfind("abcabcabcd")) == -1, b + 7, "rfind longer than the text")
        ck(at(h[..6].rfind("abc")) == 3, b + 8, "rfind up to an offset")
        ck(at(h[..5].rfind("abc")) == 0, b + 9, "rfind up to inside a match")
        ck(at(h[..2].rfind("abc")) == -1, b + 10, "rfind up to before any match")
        var e = mk(k, "")
        ck(at(e.rfind("")) == 0 && at(e.rfind("a")) == -1, b + 11, "rfind in empty")
        var d = mk(k, "baaa")
        ck(at(d.rfind("aa")) == 2 && at(d.rfind("ba")) == 0, b + 12, "rfind overlapping")
    }
}

fn find_char() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var h = mk(k, "aé€😀éz")
        ck(at(h.find('a')) == 0, b + 1, "find ascii char")
        ck(at(h.find(ch(0xe9))) == 1, b + 2, "find 2 byte char")
        ck(at(h.find(ch(0x20ac))) == 3, b + 3, "find 3 byte char")
        ck(at(h.find(ch(0x1f600))) == 6, b + 4, "find 4 byte char")
        ck(at(h.find('z')) == 12, b + 5, "find the last char")
        ck(at(h.find('q')) == -1, b + 6, "find an absent ascii char")
        ck(at(h.find(ch(0xe8))) == -1, b + 7, "find a char sharing a lead byte")
        ck(at(h.find(ch(0x20ad))) == -1, b + 8, "find a char sharing a prefix")
        ck(at(h.rfind(ch(0xe9))) == 10, b + 9, "rfind 2 byte char")
        ck(at(h.rfind('a')) == 0 && at(h.rfind('z')) == 12, b + 10, "rfind ascii")
        ck(at(h.rfind(ch(0x1f600))) == 6, b + 11, "rfind 4 byte")
        ck(at(h.rfind('q')) == -1, b + 12, "rfind absent")
        ck(h.contains('a') && h.contains(ch(0x20ac)) && !h.contains('q'), b + 13, "contains a char")
        var e = mk(k, "")
        ck(at(e.find('a')) == -1 && at(e.rfind('a')) == -1, b + 14, "char in empty")
        // A char whose bytes occur only as the tail of other chars.
        var tail = mk(k, "é")
        ck(at(tail.find(ch(0xa9))) == -1 && at(tail.find(ch(0xc3))) == -1, b + 15, "no match inside a char")
    }
}

fn find_predicate() {
    var h = "ab12é€34"
    var d = Pred { f: is_digit }
    ck(at(h.find(d)) == 2 && at(h.rfind(d)) == 10, 1, "find a digit")
    var w = Pred { f: is_wide }
    ck(at(h.find(w)) == 4 && at(h.rfind(w)) == 6, 2, "find a wide char")
    var n = Pred { f: never }
    ck(at(h.find(n)) == -1 && at(h.rfind(n)) == -1, 3, "a predicate that never holds")
    var a = Pred { f: always }
    ck(at(h.find(a)) == 0 && at(h.rfind(a)) == 10, 4, "a predicate that always holds")
    ck(h.contains(d) && !h.contains(n), 5, "contains a predicate")
    var empty = ""
    ck(at(empty.find(a)) == -1 && at(empty.rfind(a)) == -1, 6, "predicate on empty")
    ck(at(h[3..].find(d)) == 0 && at(h[..2].rfind(d)) == -1, 7, "predicate on ranges")
    ck(h.count(d) == 4 && h.count(w) == 2 && h.count(n) == 0, 8, "count by predicate")
}

fn contains_and_in() {
    var h = "the quick brown fox"
    ck(h.contains("quick") && h.contains("") && h.contains("fox") && h.contains("the"), 10, "contains present")
    ck(!h.contains("lazy") && !h.contains("the quick brown fox!"), 11, "contains absent")
    ck("quick" in h && !("lazy" in h), 12, "in operator, string")
    ck('q' in h && !('z' in h), 13, "in operator, char")
    ck("".contains(""), 14, "empty contains empty")
    ck(!"".contains("a") && !"".contains('a'), 15, "empty contains nothing else")
    ck("aé€".contains("é€") && !"aé€".contains("€é"), 16, "contains multi-byte")
    var big = string('a', 5000).concat("needle")
    ck(big.contains("needle") && !big.contains("needlf") && at(big.find("needle")) == 5000, 17, "contains in a long text")
}

fn starts_ends() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var s = mk(k, "héllo wörld")
        ck(s.starts_with("h") && s.starts_with("hé") && s.starts_with("héllo wörld"), b + 1, "starts_with true")
        ck(!s.starts_with("hello") && !s.starts_with("héllo wörld!") && !s.starts_with("é"), b + 2, "starts_with false")
        ck(s.starts_with(""), b + 3, "starts_with empty")
        ck(s.ends_with("d") && s.ends_with("örld") && s.ends_with("héllo wörld"), b + 4, "ends_with true")
        ck(!s.ends_with("orld") && !s.ends_with("!héllo wörld") && !s.ends_with("ö"), b + 5, "ends_with false")
        ck(s.ends_with(""), b + 6, "ends_with empty")
        ck(s.starts_with('h') && !s.starts_with('é') && s.ends_with('d') && !s.ends_with('r'), b + 7, "starts and ends with a char")
        var m = mk(k, "éa")
        ck(m.starts_with(ch(0xe9)) && !m.starts_with(ch(0xc3)) && m.ends_with('a'), b + 8, "wide first char")
        var e = mk(k, "")
        ck(e.starts_with("") && e.ends_with("") && !e.starts_with("a") && !e.ends_with("a"), b + 9, "on empty")
        var d = Pred { f: is_digit }
        var n = mk(k, "12ab34")
        ck(n.starts_with(d) && n.ends_with(d) && !mk(k, "ab").starts_with(d), b + 10, "predicate")
        ck(!e.starts_with(d) && !e.ends_with(d), b + 11, "predicate on empty")
        var w = mk(k, "x€")
        ck(w.ends_with(ch(0x20ac)) && !w.ends_with(ch(0xac)), b + 12, "ends_with 3 byte char")
        var tail = mk(k, "é")
        ck(tail.ends_with("é") && !tail.ends_with("Ã"), b + 13, "no match of half a char")
    }
}

fn count_matches() {
    ck("abcabcabc".count("abc") == 3, 20, "count")
    ck("aaaa".count("aa") == 2, 21, "count does not overlap")
    ck("aaaa".count("a") == 4 && "aaaa".count('a') == 4, 22, "count one byte")
    ck("abc".count("x") == 0, 23, "count absent")
    ck("".count("a") == 0, 24, "count in empty")
    ck("abc".count("") == 4, 25, "empty pattern matches before each char and at the end")
    ck("aé€".count("") == 4, 26, "empty pattern counts chars, not bytes")
    ck("".count("") == 1, 27, "empty in empty")
    ck("éé€é".count(ch(0xe9)) == 3, 28, "count a wide char")
    ck("abab".count("ab") == 2 && "ababa".count("aba") == 1, 29, "count after a match")
}

fn strip_and_split_once() {
    var s = "prefix:body:suffix"
    var a? = s.strip_prefix("prefix:")
    ck(a? && a == "body:suffix", 30, "strip_prefix")
    var b? = s.strip_prefix("body")
    ck(!b?, 31, "strip_prefix absent")
    var c? = s.strip_suffix(":suffix")
    ck(c? && c == "prefix:body", 32, "strip_suffix")
    var d? = s.strip_suffix("prefix")
    ck(!d?, 33, "strip_suffix absent")
    var e? = s.strip_prefix("")
    var f? = s.strip_suffix("")
    ck(e? && e == s && f? && f == s, 34, "strip empty")
    var g? = s.strip_prefix(s)
    ck(g? && g.is_empty(), 35, "strip the whole text")
    var h? = "é€".strip_prefix(ch(0xe9))
    var i? = "é€".strip_suffix(ch(0x20ac))
    ck(h? && h == "€" && i? && i == "é", 36, "strip a char")
    var j? = "123abc".strip_prefix(Pred { f: is_digit })
    ck(j? && j == "23abc", 37, "strip one char by predicate")
    var k? = "abc".strip_prefix("abcd")
    ck(!k?, 38, "strip a longer prefix")
    var p? = s.strip_prefix("prefix:")
    ck(p? && p.is_view() && p.data() == s.data() + 7, 39, "a stripped string is a view")
    var so? = "key=val=more".split_once("=")
    ck(so? && so.0 == "key" && so.1 == "val=more", 40, "split_once")
    var rso? = "key=val=more".rsplit_once('=')
    ck(rso? && rso.0 == "key=val" && rso.1 == "more", 41, "rsplit_once")
    var none? = "keyval".split_once("=")
    var none2? = "keyval".rsplit_once("=")
    ck(!none? && !none2?, 42, "split_once absent")
    var ed? = "=a=".split_once("=")
    ck(ed? && ed.0.is_empty() && ed.1 == "a=", 43, "split_once at the start")
    var ed2? = "=a=".rsplit_once("=")
    ck(ed2? && ed2.0 == "=a" && ed2.1.is_empty(), 44, "rsplit_once at the end")
    var mb? = "aé€b".split_once(ch(0x20ac))
    ck(mb? && mb.0 == "aé" && mb.1 == "b", 45, "split_once on a wide char")
    var em? = "abc".split_once("")
    ck(em? && em.0.is_empty() && em.1 == "abc", 46, "split_once on the empty pattern")
    var wd? = "ab12cd".split_once(Pred { f: is_digit })
    ck(wd? && wd.0 == "ab" && wd.1 == "2cd", 47, "split_once by predicate")
}

fn trim_matches_member() {
    ck("xxabcxx".trim_matches('x') == "abc", 50, "trim a char from both ends")
    ck("xxxx".trim_matches('x').is_empty(), 51, "trim everything")
    ck("abc".trim_matches('x') == "abc", 52, "trim nothing")
    ck("".trim_matches('x').is_empty(), 53, "trim empty")
    ck("ababcabab".trim_matches("ab") == "c", 54, "trim a string repeatedly")
    ck("12abc34".trim_matches(Pred { f: is_digit }) == "abc", 55, "trim by predicate")
    ck("éé€éé".trim_matches(ch(0xe9)) == "€", 56, "trim a wide char")
    ck("abc".trim_matches("") == "abc", 57, "trim the empty pattern")
    ck("aaa".trim_matches("aa") == "a", 58, "trim does not overlap")
    ck("€x€".trim_matches(ch(0x20ac)) == "x", 59, "trim 3 byte chars")
}

fn search_against_a_hand_loop() {
    // The hay is built from a small alphabet so matches are frequent; every
    // needle of length 0..3 is searched and compared with a byte loop.
    var alpha = "aé€"
    var hay   = string()
    var seed: u32 = 12345
    for var i = 0; i < 60; i += 1 {
        seed = seed * 1103515245 + 12345
        var pick = (seed >> 16) % 3
        if pick == 0 {
            hay.push('a')
        } else if pick == 1 {
            hay.push(ch(0xe9))
        } else {
            hay.push(ch(0x20ac))
        }
    }

    var needles = ["a", "é", "€", "aa", "aé", "é€", "€a", "aaa", "é€a", "€€€", "a€é"]
    var hb = hay.bytes()
    var ok = true
    for *nd in needles {
        var nb = nd->bytes()
        var first = -1
        var last  = -1
        var cnt   = 0
        var i: usize = 0
        while i + nb.size() <= hb.size() {
            var same = true
            for var j: usize = 0; j < nb.size(); j += 1 {
                if hb[i + j] != nb[j] {
                    same = false
                    break
                }
            }

            if same {
                if first < 0 {
                    first = i as i32
                }

                last = i as i32
                cnt += 1
                i += nb.size()
            } else {
                i += 1
            }
        }

        // The last match start, by scanning every position.
        var lastpos = -1
        for var s: usize = 0; s + nb.size() <= hb.size(); s += 1 {
            var same = true
            for var j: usize = 0; j < nb.size(); j += 1 {
                if hb[s + j] != nb[j] {
                    same = false
                    break
                }
            }

            if same {
                lastpos = s as i32
            }
        }

        if at(hay.find(*nd)) != first as isize || at(hay.rfind(*nd)) != lastpos as isize || hay.count(*nd) != cnt as usize {
            ok = false
        }
    }

    ck(ok, 70, "find, rfind and count agree with a byte loop")
}

fn main() -> i32 {
    find_string()
    rfind_string()
    find_char()
    find_predicate()
    contains_and_in()
    starts_ends()
    count_matches()
    strip_and_split_once()
    trim_matches_member()
    search_against_a_hand_loop()
    return CODE
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %t.o2.exe

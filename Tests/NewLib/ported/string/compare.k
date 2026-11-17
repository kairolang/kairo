// Comparison and hashing: ==, !=, <, <=, >, >=, <=> over a literal, a view and
// a heap string; a proper prefix orders first; bytes order as code points
// (so a 4 byte char sorts above a 3 byte one and above every ASCII char);
// strings with an embedded NUL; equal text hashes alike whatever the state;
// strings as map keys and in sorted order.
// Cases from libc++ test/std/strings/basic.string/string.nonmembers/string_comparison/
// Cases from libc++ test/std/strings/basic.string/string.ops/string_compare/
// Cases from Rust library/alloctests/tests/str.rs (test_str_compare, cmp)

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

fn mk(kind: i32, const src: string) -> string {
    if kind == 0 {
        return src.copy()
    }

    if kind == 1 {
        return src.view()
    }

    return src.to_owned()
}

fn hash_of(const s: string, seed: u64) -> u64 {
    var h = Hasher(seed)
    s.hash(&h)
    return h.finish()
}

// `a` orders strictly before `b`, tested through every operator, both ways
// round, in each pairing of the three states.
fn before(const a: string, const b: string, id: i32, const name: string) {
    for var ka = 0; ka < 3; ka += 1 {
        for var kb = 0; kb < 3; kb += 1 {
            var x = mk(ka, a)
            var y = mk(kb, b)
            var ok = x < y && x <= y && !(x > y) && !(x >= y) && !(x == y) && x != y
            ok = ok && y > x && y >= x && !(y < x) && !(y <= x) && y != x
            ok = ok && (x <=> y) == Ordering::Less && (y <=> x) == Ordering::Greater
            ck(ok, id, name)
        }
    }
}

fn same(const a: string, const b: string, id: i32, const name: string) {
    for var ka = 0; ka < 3; ka += 1 {
        for var kb = 0; kb < 3; kb += 1 {
            var x = mk(ka, a)
            var y = mk(kb, b)
            var ok = x == y && !(x != y) && x <= y && x >= y && !(x < y) && !(x > y)
            ok = ok && (x <=> y) == Ordering::Equal
            ck(ok, id, name)
        }
    }
}

fn equality_and_order() {
    same("", "", 1, "empty equals empty")
    same("abc", "abc", 2, "equal ascii")
    same("héllo", "héllo", 3, "equal non-ascii")
    same("a\x00b", "a\x00b", 4, "equal with a NUL")
    before("", "a", 10, "empty before anything")
    before("a", "b", 11, "a before b")
    before("a", "aa", 12, "a prefix orders first")
    before("abc", "abd", 13, "differ in the last byte")
    before("abc", "b", 14, "differ in the first byte")
    before("Z", "a", 15, "upper before lower")
    before("a", "é", 16, "ascii before 2 byte")
    before("é", "€", 17, "2 byte before 3 byte")
    before("€", "😀", 18, "3 byte before 4 byte")
    before("z", "😀", 19, "ascii before 4 byte")
    before("é", "ê", 20, "adjacent 2 byte chars")
    before("a\x00b", "a\x00c", 21, "NUL then differ")
    before("a", "a\x00", 22, "a prefix before a NUL extension")
    before("a\x00", "a\x01", 23, "NUL before 1")
    before("abcdefgh", "abcdefgi", 24, "differ in the 8th byte")
    before("abcdefgh", "abcdefghi", 25, "word-long prefix")
    before("abcdefghijklmnop", "abcdefghijklmnoq", 26, "differ in the 16th byte")
    before("abcdefghijklmnopq", "abcdefghijklmnopr", 27, "differ past two words")
    before("abcdefghabcdefgh", "abcdefghabcdefgi", 28, "equal first word, differ in the second")
    before("héllo wörld", "héllo wörle", 29, "multi-byte then ascii differ")
    before("aaaaaaaaé", "aaaaaaaaê", 30, "differ inside a word-sized prefix match")
    before("\x7f", "é", 31, "DEL before the first 2 byte char")
    before("߿", "ࠀ", 32, "last 2 byte before first 3 byte")
    before("￿", "\U00010000", 33, "last 3 byte before first 4 byte")
}

fn not_equal_pairs() {
    var pairs: [string] = ["", "a", "ab", "abc", "é", "e", "€", "😀", "a\x00", "A", "abcdefgh", "abcdefghi"]
    var ok = true
    for var i: usize = 0; i < pairs.size(); i += 1 {
        for var j: usize = 0; j < pairs.size(); j += 1 {
            var eq = pairs[i] == pairs[j]
            if eq != (i == j) {
                ok = false
            }

            var lt = pairs[i] < pairs[j]
            var gt = pairs[i] > pairs[j]
            if (i == j) && (lt || gt) {
                ok = false
            }

            if (i != j) && (lt == gt) {
                ok = false
            }
        }
    }

    ck(ok, 40, "a pairwise table is a strict total order on distinct strings")
}

fn transitive_sort() {
    var words: [string] = ["pear", "apple", "é", "Apple", "", "apple pie", "zebra", "😀", "€", "applé", "a", "z"]
    words.sort()

    var ok = true
    for var i: usize = 1; i < words.size(); i += 1 {
        if !(words[i - 1] <= words[i]) {
            ok = false
        }
    }

    ck(ok, 50, "sorted by < is non-decreasing")
    ck(words[0] == "" && words[1] == "Apple" && words[2] == "a", 51, "sorted prefix")
    ck(words[words.size() - 1] == "😀" && words[words.size() - 2] == "€", 52, "sorted suffix")
}

fn hashing() {
    var lit = "héllo wörld"
    for var seed: u64 = 0; seed < 4; seed += 1 {
        var h = hash_of(lit, seed)
        ck(hash_of(lit.to_owned(), seed) == h, 60, "heap hash equals literal hash")
        ck(hash_of(lit.view(), seed) == h, 61, "view hash equals literal hash")
        var cut = "xxhéllo wörldxx"[2..15]
        ck(hash_of(cut, seed) == h, 62, "cut view hash equals literal hash")
        var roomy = string::with_capacity(500)
        roomy += lit
        ck(hash_of(roomy, seed) == h, 63, "spare capacity does not reach the hash")
        ck(hash_of("héllo wörle", seed) != h, 64, "different text, different hash")
        ck(hash_of("", seed) != h, 65, "empty hashes differently")
        ck(hash_of("a", seed) != hash_of("b", seed), 66, "one byte")
        ck(hash_of("a\x00", seed) != hash_of("a", seed), 67, "a trailing NUL counts")
    }

    ck(hash_of("abc", 1) != hash_of("abc", 2), 68, "the seed changes the hash")
    var h1 = Hasher(7)
    "ab".hash(&h1)
    "c".hash(&h1)
    var h2 = Hasher(7)
    "a".hash(&h2)
    "bc".hash(&h2)
    ck(h1.finish() != h2.finish(), 69, "the length is part of the hash")
}

fn as_map_keys() {
    var m: {string: i32} = {}
    m.insert("héllo", 1)
    m.insert("hello", 2)
    m.insert("", 3)
    m.insert("😀", 4)
    var probe = "héllo xx"[0..6].view()
    ck(m.size() == 4, 70, "four distinct keys")
    var *a? = m.get(probe)
    ck(a? && *a == 1, 71, "lookup by a view")
    var key = string()
    key.push_str("hel")
    key.push_str("lo")
    var *b? = m.get(key)
    ck(b? && *b == 2, 72, "lookup by a built string")
    var *c? = m.get("")
    ck(c? && *c == 3, 73, "lookup of the empty string")
    var *d? = m.get("héll")
    ck(!d?, 74, "a missing key")
    var old? = m.insert("héllo".to_owned(), 9)
    ck(old? && old == 1 && m.size() == 4, 75, "an equal heap key replaces")
    ck(m.contains("😀") && !m.contains("😁"), 76, "contains by string")
}

fn main() -> i32 {
    equality_and_order()
    not_equal_pairs()
    transitive_sort()
    hashing()
    as_map_keys()
    return CODE
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %t.o2.exe

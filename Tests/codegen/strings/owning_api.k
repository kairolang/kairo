// The owning string's whole API (Lib/builtin/string.k), one check per
// entry: each failing check returns its own code, so a failure names itself.
// Construction (literal, default, copy, C string, pointer + length),
// `+` / `+=` / `=` (a string is MOVE: `=` moves, `copy()` duplicates),
// the comparisons `<=>` derives, size / is_empty / codepoints / data /
// `[]` (the char at a byte) / get, range views, starts_with / ends_with /
// find / rfind (string and char), push / push_str, reserve; copy
// independence, a literal left intact by writes to its copy, codepoints
// kept through every mutation, growth past 1024 bytes, and f-strings
// feeding and fed by owned strings.

fn takes(const s: string) -> usize { return s.size() }

fn join(const a: string, const b: string) -> string { return a.copy() + b }

fn at(r: usize?) -> usize { return r ?? usize::MAX }

fn main() -> i32 {
    // construction
    var lit = "héllo"                       // 6 bytes, 5 codepoints, static
    if (lit.size() != 6) || (lit.codepoints() != 5) || (lit.capacity() != 0) || !lit.is_static() { return 1 }
    var d = string()
    if !d.is_empty() || (d.size() != 0) || (d != "") { return 2 }
    var c = lit.copy()                      // a copy of a literal stays a literal
    if !c.is_static() || (c.data() != lit.data()) || (c != lit) { return 3 }
    var cs = string(lit.data())             // from a NUL-terminated pointer: owned
    if !cs.is_owned() || (cs != lit) || (cs.codepoints() != 5) { return 4 }
    var pl = string(lit.data(), 3)          // "hé": 3 bytes, 2 codepoints
    if (pl.size() != 3) || (pl.codepoints() != 2) || (pl != "hé") { return 5 }
    var e0 = string(lit.data(), 0)
    if !e0.is_empty() || (e0.capacity() != 0) { return 6 }

    // copy independence, and a literal never written
    var m = "H" + lit[1..]                  // built from a view of the literal
    if (m != "Héllo") || (lit != "héllo") || !m.is_owned() { return 7 }
    var o = m.copy()                        // deep copy of an owned string
    o.push('!')
    if (o.data() == m.data()) || (m != "Héllo") || (o != "Héllo!") { return 8 }
    var a = "x"
    a = m.copy()                            // `=` takes the copy
    m.push('!')
    if (a != "Héllo") || (m != "Héllo!") { return 9 }
    var mv = "y"
    mv = m                                  // `=` moves: m is not read again
    if mv != "Héllo!" { return 10 }

    // `+`, `+=`, codepoints through them
    var j = lit.copy() + " " + "wörld"
    if (j != "héllo wörld") || (j.size() != 13) || (j.codepoints() != 11) { return 11 }
    j += "€"
    if (j.codepoints() != 12) || (j.size() != 16) { return 12 }
    var twice = "ab"
    twice += twice.copy()
    twice += twice.copy()
    if twice != "abababab" { return 13 }
    if join("a", "b") != "ab" { return 14 }
    var empty_app = "lit"
    empty_app += ""
    if (empty_app != "lit") || !empty_app.is_static() { return 15 }   // appending nothing does not own

    // comparisons
    if !("abc" < "abd") || !("ab" < "abc") || ("abc" < "ab") || !("b" > "abc") { return 16 }
    if ("abc" == "abd") || ("abc" != "abc") || !("" == string()) || ("a" == "") { return 17 }
    if !("abc" <= "abc") || !("abd" >= "abc") { return 18 }

    // reading: `[]` is the char that starts at a byte; get is null off a boundary
    const k = j.copy()
    if (k[0] != 'h') || ((j[1] as u32) != 0xE9) || (takes(k) != 16) { return 19 }
    if (j.get(2) != null) || (j.get(16) != null) || !(j.get(3) === j[3]) { return 20 }

    // range views: no copy, sharing the bytes they view
    var s = "hello world"
    var w = s[6..11]
    if (w != "world") || !w.is_view() || (w.capacity() != 0) { return 21 }
    var h = s[..5]
    if (h != "hello") || !h.is_view() { return 22 }
    if (s[6..] != "world") || !s[3..3].is_empty() { return 23 }
    var u = "añb€c"[1..7]                   // "ñb€": 6 bytes, 3 codepoints
    if (u != "ñb€") || (u.codepoints() != 3) { return 24 }
    var hs = j[0..5]                        // from an owned string
    if (hs != "héll") || (hs.codepoints() != 4) || !hs.is_view() || (hs.data() != j.data()) { return 25 }
    var ho = hs.to_owned()
    if !ho.is_owned() || (ho != "héll") || (ho.data() == hs.data()) { return 26 }

    // prefix, suffix, find, rfind
    if !s.starts_with("hello") || s.starts_with("world") || !s.starts_with("") || "".starts_with("a") { return 27 }
    if !s.starts_with('h') || s.starts_with('w') || string().starts_with('a') { return 28 }
    if !s.ends_with("world") || s.ends_with("hello") || !s.ends_with('d') || string().ends_with('d') { return 29 }
    if (at(s.rfind("o")) != 7) || (at(s.rfind("hello")) != 0) || (at(s.rfind("xyz")) != usize::MAX) || (at(s.rfind("hello world!")) != usize::MAX) { return 30 }
    if (at(s.rfind('o')) != 7) || (at(s.rfind('z')) != usize::MAX) || (at(s.find('o')) != 4) || (at(string().rfind('a')) != usize::MAX) { return 31 }

    // push, reserve, growth past 1024 bytes (mimalloc's small range)
    var g = string()
    g.reserve(10)
    if g.capacity() < 10 { return 32 }
    for var i: usize = 0; i < 3000; ++i { g.push('a' as u32 + (i % 26) as u32) }
    if (g.size() != 3000) || (g.codepoints() != 3000) || (g[2999] != 'j') { return 33 }
    var big = g.copy() + g
    if (big.size() != 6000) || !big.ends_with(g) || !big.starts_with(g) { return 34 }
    var r = "lit"
    r.reserve(100)
    if (r.capacity() < 100) || (r != "lit") || !r.is_owned() { return 35 }
    var mb = string()
    mb.push_str("€")
    mb.push_str(lit[1..3])                  // "é" from a view
    if (mb != "€é") || (mb.codepoints() != 2) || (mb.size() != 5) { return 36 }

    // f-strings: built with the same allocator, owned, mixed with the API
    var n = 7
    var f = f"n={n} {lit}"
    if (f != "n=7 héllo") || (f.codepoints() != 9) || !f.is_owned() { return 37 }
    f += "!"
    var ff = f"{f}|{f[0..3]}"
    if ff != "n=7 héllo!|n=7" { return 38 }

    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42

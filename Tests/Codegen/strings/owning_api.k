// The owning string's whole API (Lib/builtin/string.k), one check per
// entry: each failing check returns its own code, so a failure names itself.
// Construction (literal, default, copy, C string, pointer + length),
// `+` / `+=` / `=`, the comparisons `<=>` derives, size / empty / length /
// raw / `[]` (const and mutable), subslice, starts_with / ends_with / rfind
// (string and byte), push_back, reserve; copy independence, a literal left
// intact by writes to its copy, codepoints kept through every mutation,
// growth past 1024 bytes, and f-strings feeding and fed by owned strings.

fn takes(const s: string) -> usize { return s.size() }

fn join(a: string, b: string) -> string { return a + b }

fn main() -> i32 {
    // construction
    var lit = "héllo"                       // 6 bytes, 5 codepoints, borrowed
    if (lit.size() != 6) || (lit.codepoints() != 5) || (lit.capacity() != 0) { return 1 }
    var d = string()
    if (!d.empty()) || (d.size() != 0) || (d.raw()[0] != 0) { return 2 }
    var c = lit                             // a copy of a literal still borrows
    if (c.capacity() != 0) || (c.raw() != lit.raw()) { return 3 }
    var cs = string(lit.raw())              // from a NUL-terminated pointer: owned
    if (cs.capacity() == 0) || (cs != lit) || (cs.codepoints() != 5) { return 4 }
    var pl = string(lit.raw(), 3)           // "hé": 3 bytes, 2 codepoints
    if (pl.size() != 3) || (pl.codepoints() != 2) || (pl.raw()[3] != 0) { return 5 }
    var e0 = string(lit.raw(), 0)
    if (!e0.empty()) || (e0.capacity() != 0) { return 6 }

    // copy independence, and a literal never written
    var m = lit
    m[0] = 72                               // 'H': the copy moves to the heap first
    if (m != "Héllo") || (lit != "héllo") || (m.capacity() == 0) { return 7 }
    var o = m                               // deep copy of an owned string
    o[1] = 69
    if (o.raw() == m.raw()) || (m != "Héllo") { return 8 }
    var a = "x"
    a = m                                   // `=` copies too
    m.push_back(33)
    if (a != "Héllo") || (m != "Héllo!") { return 9 }

    // `+`, `+=`, codepoints through them
    var j = lit + " " + "wörld"
    if (j != "héllo wörld") || (j.size() != 13) || (j.codepoints() != 11) { return 10 }
    j += "€"
    if (j.codepoints() != 12) || (j.size() != 16) { return 11 }
    var self_app = "ab"
    self_app += self_app
    self_app += self_app
    if self_app != "abababab" { return 12 }
    if join("a", "b") != "ab" { return 13 }
    var empty_app = "lit"
    empty_app += ""
    if empty_app.capacity() != 0 { return 14 }   // appending nothing does not own

    // comparisons
    if !("abc" < "abd") || !("ab" < "abc") || ("abc" < "ab") || !("b" > "abc") { return 15 }
    if ("abc" == "abd") || ("abc" != "abc") || !("" == string()) || ("a" == "") { return 16 }
    if !("abc" <= "abc") || !("abd" >= "abc") { return 17 }

    // reading
    const k = j
    if (k[0] != 104) || (j[1] != 0xC3) || (takes(k) != 16) || (j.length() != 16) { return 18 }

    // subslice: clamped; a borrowed suffix shares, everything else copies
    var s = "hello world"
    var w = s.subslice(6, 5)
    if (w != "world") || (w.capacity() != 0) || (w.raw() != &s.raw()[6]) { return 19 }
    var h = s.subslice(0, 5)
    if (h != "hello") || (h.capacity() == 0) || (h.raw()[5] != 0) { return 20 }
    if (s.subslice(6, 100) != "world") || (!s.subslice(50, 2).empty()) || (!s.subslice(3, 0).empty()) { return 21 }
    var u = "añb€c".subslice(1, 6)          // "ñb€": 6 bytes, 3 codepoints
    if (u != "ñb€") || (u.codepoints() != 3) { return 22 }
    var hs = j.subslice(0, 5)               // from an owned string
    if (hs != "héll") || (hs.codepoints() != 4) { return 23 }

    // prefix, suffix, rfind
    if (!s.starts_with("hello")) || s.starts_with("world") || (!s.starts_with("")) || "".starts_with("a") { return 24 }
    if (!s.starts_with(104)) || s.starts_with(119) || string().starts_with(0) { return 25 }
    if (!s.ends_with("world")) || s.ends_with("hello") || (!s.ends_with(100)) || string().ends_with(100) { return 26 }
    if (s.rfind("o") != 7) || (s.rfind("hello") != 0) || (s.rfind("xyz") != usize::MAX) || (s.rfind("hello world!") != usize::MAX) { return 27 }
    if (s.rfind(111) != 7) || (s.rfind(122) != usize::MAX) || (s.rfind("") != 11) || (string().rfind(97) != usize::MAX) { return 28 }

    // push_back, reserve, growth past 1024 bytes (mimalloc's small range)
    var g = string()
    g.reserve(10)
    if g.capacity() < 11 { return 29 }
    for var i: usize = 0; i < 3000; ++i { g.push_back(97 + (i % 26) as u8) }
    if (g.size() != 3000) || (g.codepoints() != 3000) || (g[2999] != 106) || (g.raw()[3000] != 0) { return 30 }
    var big = g + g
    if (big.size() != 6000) || (!big.ends_with(g)) || (!big.starts_with(g)) { return 31 }
    var r = "lit"
    r.reserve(2)                            // no more than it has: stays borrowed
    if r.capacity() != 0 { return 32 }
    r.reserve(100)
    if (r.capacity() < 101) || (r != "lit") { return 33 }
    var mb = string()
    mb.push_back(0xE2); mb.push_back(0x82); mb.push_back(0xAC)   // "€" byte by byte
    if (mb != "€") || (mb.codepoints() != 1) { return 34 }

    // f-strings: built with the same allocator, owned, mixed with the API
    var n = 7
    var f = f"n={n} {lit}"
    if (f != "n=7 héllo") || (f.codepoints() != 9) || (f.capacity() == 0) { return 35 }
    f += "!"
    var ff = f"{f}|{f.subslice(0, 3)}"
    if ff != "n=7 héllo!|n=7" { return 36 }

    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42

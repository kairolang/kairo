// `{T}` (Lib/builtin/containers/hash_set.k): every entry of the API
// Compiler/ uses of Stage 0's set (private/IMPORTANT/api-surface.md), with
// integer and string elements. Each check returns its own number on
// failure; 100 is success.

fn main() -> i32 {
    var s: {u32}
    if !s.empty() || s.contains(1u32) { return 1 }
    // insert: true only for a new element (Stage 0's `.second`)
    if !s.insert(3u32) || !s.insert(1u32) || !s.insert(2u32) { return 2 }
    if s.insert(1u32) { return 3 }
    if (s.size() != 3) || !s.contains(2u32) || s.contains(4u32) { return 4 }

    // find / end, begin..end and `for x in s`: insertion order
    if s.find(9u32) != s.end() { return 5 }
    if *s.find(2u32) != 2u32 { return 6 }
    var order: u32 = 0
    for var *it = s.begin(); it != s.end(); it = it + 1 { order = order * 10u32 + *it }
    if order != 312u32 { return 7 }
    order = 0
    for x in s { order = order * 10u32 + x }
    if order != 312u32 { return 8 }
    var n: u32 = 0
    for *p in s.items() { n += *p }
    if n != 6u32 { return 9 }

    // erase (swap-remove) and erase_ordered
    if !s.erase(3u32) || s.erase(3u32) { return 10 }
    order = 0
    for x in s { order = order * 10u32 + x }
    if order != 21u32 { return 11 }                 // 2 took 3's place
    s.insert(5u32)
    if !s.erase_ordered(2u32) { return 12 }
    order = 0
    for x in s { order = order * 10u32 + x }
    if order != 15u32 { return 13 }

    // copy ctor and `=` are deep
    var c = s
    c.insert(9u32)
    if s.contains(9u32) || !c.contains(9u32) { return 14 }
    var d: {u32}
    d = c
    c.clear()
    if (d.size() != 3) || (c.size() != 0) || c.contains(9u32) { return 15 }
    d.reserve(500)
    if (d.capacity() < 500) || (d.size() != 3) { return 16 }

    // strings
    var w: {string}
    w.insert("x")
    w.insert("yy")
    if w.insert("x") || !w.contains("yy") || w.contains("z") { return 17 }
    if !w.erase("x") || (w.size() != 1) { return 18 }

    // literals: written order, a repeat keeps its first place
    var lit: {i32} = {5, 6, 5, 7}
    if lit.size() != 3 { return 19 }
    var t = 0
    for x in lit { t = t * 10 + x }
    if t != 567 { return 20 }
    return 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 100

// A map literal, then a store and a load by key (collections.mdx, Maps).
//
// ListLiteralLowering builds it as `HashMap(<the entries as a slice of
// (K, V) tuples>)` (Lib/builtin/containers/hash_map.k); the ticket "[Lower]
// Set and map literals have no lowering and ICE" (2026-10-26) is fixed by
// that lowering.

fn main() -> i32 {
    var ages: {string: i32} = {"Alice": 30, "Bob": 25}
    ages["Charlie"] = 35
    return ages["Alice"] + ages["Charlie"]      // 30 + 35
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 65

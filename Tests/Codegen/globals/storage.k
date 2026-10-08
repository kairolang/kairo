// File-scope `var`, `const` and `static` are namespace-scope
// variables: an `extern` declaration in the interface (a `const` has
// external linkage in C++ only behind one), then the definition in source
// order, which is C++'s initialization order within the TU. `static` is
// storage duration, not linkage: it never spells C++'s `static`.

const BASE: i32 = 10
const NEXT: i32 = BASE + 1
static counter: i32 = 5
var total: i32 = 0
priv const HIDDEN: i32 = 3
const PTR: *i32 = &total

module cfg {
    pub const K: i32 = 7
    pub var n: i32 = 1
}

fn bump() -> i32 {
    counter = counter + 1
    total = total + NEXT
    return counter
}

fn main() -> i32 {
    var c = bump()                      // counter 6, total 11
    *PTR = total + HIDDEN               // total 14
    cfg::n = cfg::n + cfg::K            // n 8
    return c + total * 2 + BASE + cfg::n    // 6 + 28 + 10 + 8 == 52
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=DECL
// DECL-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}storage.k
// DECL: {{^ *}}extern signed int const BASE;
// DECL: {{^ *}}extern signed int const NEXT;
// DECL: {{^ *}}extern signed int counter;
// DECL: {{^ *}}extern signed int total;
// DECL: namespace {
// DECL-NEXT: {{^ *}}extern signed int const HIDDEN;
// DECL: {{^ *}}extern signed int{{ ?}}*{{ ?}}const PTR;
// DECL: namespace storage::cfg {
// DECL-NEXT: {{^ *}}extern signed int const K;

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=DEF
// DEF-LABEL: CODEGEN C++: {{.*}}storage.k
// DEF: {{^ *}}signed int const BASE = 10;
// DEF: {{^ *}}signed int const NEXT ={{.*}}::storage::BASE + 1
// DEF: {{^ *}}signed int counter = 5;
// DEF: {{^ *}}signed int total = 0;
// DEF: namespace {
// DEF-NEXT: {{^ *}}signed int const HIDDEN = 3;
// DEF: {{^ *}}signed int{{ ?}}*{{ ?}}const PTR ={{.*}}::storage::total
// DEF: namespace storage::cfg {
// DEF-NEXT: {{^ *}}signed int const K = 7;

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 52

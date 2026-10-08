import lib::*

fn main() -> i32 {
    hit()
    hits = hits + 1
    return LIMIT + hit()              // 40 + 3 == 43
}

// --- lit wiring -----------------------------------------------------------
// A `pub const` and a `pub var` defined in lib and read (and, for the var,
// written) from main. lib's definition is the only one; main reaches it
// through the `extern` in its preamble. A `const` with no prior `extern` in
// lib's own TU would have internal linkage there and fail to link here.
//
// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=DECL
// DECL-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}main.k
// DECL: {{^ *}}extern signed int const LIMIT;
// DECL: {{^ *}}extern signed int hits;
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 43

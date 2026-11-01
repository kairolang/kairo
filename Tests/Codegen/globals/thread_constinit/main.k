import lib::*

fn main() -> i32 {
    hit()
    hits += 1
    return LIMIT + seeded + hits - 2      // 40 + 2 + 2 - 2 == 42
}

// --- lit wiring -----------------------------------------------------------
// P229: a `thread` global whose initializer is a literal is `constinit` on
// lib's definition and on main's `extern` alike, so main reaches `hits` and
// `LIMIT` directly in TLS: no `_ZTW` wrapper, no weak `_ZTH` init function
// tested on every access. `seeded` runs a function on first use, so it keeps
// both -- the control that the grep sees the wrapper when there is one.
//
// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=DECL
// DECL-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}main.k
// DECL-DAG: {{^ *}}extern constinit thread_local signed int hits;
// DECL-DAG: {{^ *}}extern constinit thread_local signed int const LIMIT;
// DECL-DAG: {{^ *}}extern thread_local signed int seeded;
//
// REQUIRES: clang
// RUN: rm -rf %t.ir
// RUN: %kairo %s --emit=llvm-ir -O2 --cache-dir %t.ir
// RUN: grep -qE '_ZTH[A-Za-z0-9_]*6seeded' %t.ir/main.ll
// RUN: { ! grep -E '_ZT[HW][A-Za-z0-9_]*(4hits|5LIMIT)' %t.ir/main.ll; }
//
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42

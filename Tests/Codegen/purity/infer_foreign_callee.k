// -finfer-purity trusts a C/C++ callee that clang itself marks: `abs` is
// [[gnu::const]] and `strlen` [[gnu::pure]] (clang's builtin table adds the
// attribute to the library declaration), so a Kairo function calling only
// them keeps the promise. `rand` is unmarked and keeps its callers impure.
// The marks are read off the clang decl, i.e. as clang sees them under OUR
// invocation (Kairo's own compile line has no -fmath-errno, so it also marks
// `sqrt`; that is clang's verdict for this invocation, not asserted here).
// The written promises follow the same rule (infer_foreign_const_rejects.k).

import std::c_char

ffi "c" import "string.h"
ffi "c" import "stdlib.h"

fn len(s: unsafe *const c_char) -> usize { return strlen(s) }
fn absval(x: i32) -> i32 { return abs(x) }
fn absval2(x: i32) -> i32 { return absval(x) + 1 }
fn roll() -> i32 { return rand() }
fn roll2() -> i32 { return roll() + 1 }
fn const_abs(x: i32) const -> i32 { return abs(x) }
@pure fn pure_len(s: unsafe *const c_char) -> usize { return strlen(s) }

fn main() -> i32 {
    if absval2(-4) != 5 { return 1 }
    if roll2() < 1 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -finfer-purity --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=INF
// INF-DAG: __attribute{{(__)?}}((pure)) decltype(sizeof(0)) len(
// INF-DAG: __attribute{{(__)?}}((const)) signed int absval(
// INF-DAG: __attribute{{(__)?}}((const)) signed int absval2(
// INF-DAG: __attribute{{(__)?}}((pure)) decltype(sizeof(0)) pure_len(
// INF-DAG: __attribute{{(__)?}}((const)) signed int const_abs(

// RUN: { %kairo %s -finfer-purity --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=NEG
// NEG-NOT: (({{const|pure}})) signed int {{(roll2?)}}(

// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: rm -rf %t.d
// RUN: %kairo %s -finfer-purity -O2 -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe

// REQUIRES: clang

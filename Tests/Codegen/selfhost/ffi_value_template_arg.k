// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// An imported C++ class template with a non-type argument:
// `std::array<i32, 4>` (and llvm::SmallVector<T, N>, which Compiler/
// imports in 8 files).
//
// XFAIL: *
// Waiting on codegen for an integer template argument of an imported
// template: it type-checks and ICEs, "EmitIR: unresolved type reached
// codegen; sema gate failure". Type arguments alone work (vector<i32>,
// map<i32, i32>, unordered_map<u64, i32>, set<i32>).
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

ffi "c++" import "array"

fn main() -> i32 {
    var a: cxx::std::array<i32, 4>
    a[1] = 5
    return a[1] + (a.size() as i32)           // 5 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9

// `eval` bindings and `eval fn` at file scope and in a function body
// compile as the module form does: a namespace-scope binding is a
// `constexpr` definition behind the interface's `extern const`
// declaration, a function-local one is a `constexpr` local, and an `eval
// fn` is `consteval` (EVAL.md 1.1).
// Before the parser took them as declarations, `eval N = 10` at file scope
// was an expression statement and `N` was undeclared.

eval N = 10
eval M: i32 = 4
eval fn sq(x: i32) -> i32 { return x * x }

module m {
    pub eval K = 2
}

fn f() -> i32 {
    eval k: i32 = 4
    eval j = 5
    return k + j + N + M + sq(2) + m::K   // 4 + 5 + 10 + 4 + 4 + 2 == 29
}

fn main() -> i32 { return f() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=DEF
// DEF-LABEL: CODEGEN C++: {{.*}}eval_file_scope.k
// DEF: {{^ *}}extern signed int const N;
// DEF: {{^ *}}extern signed int const M;
// DEF: {{^ *}}consteval signed int sq(signed int x) noexcept;
// DEF: {{^ *}}constexpr signed int const N = 10;
// DEF: {{^ *}}constexpr signed int const M = 4;
// DEF: {{^ *}}constexpr signed int k = 4;
// DEF-NEXT: {{^ *}}constexpr signed int j = 5;

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 29

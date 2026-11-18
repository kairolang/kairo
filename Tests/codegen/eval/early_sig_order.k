// An early eval fn whose own signature computes from another early item
// (`f`'s parameter is `[usize; g(1)]`) is declared only once that item is
// defined: C++ evaluates `g(1)` where `f` is declared. `h`, written first,
// calls `f`, so it is defined after `g` too, past `f`'s declaration.
eval fn h(n: usize) -> usize { var a: [usize; g(1)]  a[0] = 0  a[1] = 4  return f(n, a) }
eval fn f(n: usize, const a: [usize; g(1)]) -> usize { return n + a[1] }
eval fn g(n: usize) -> usize { return n + 1 }
struct S { var d: [i32; h(2)] }
fn main() -> i32 {
    var s = S()
    s.d[5] = 3
    return (sizeof(S) as i32) + s.d[5]   // 6 * 4 + 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}early_sig_order.k
// IR-NOT:  f(decltype(sizeof(0)) n, {{.*}}) noexcept;
// IR:      consteval decltype(sizeof(0)) g(decltype(sizeof(0)) n) noexcept {
// IR:      consteval decltype(sizeof(0)) f(decltype(sizeof(0)) n, {{.*}}g(1)]) noexcept;
// IR:      consteval decltype(sizeof(0)) h(decltype(sizeof(0)) n) noexcept {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 27

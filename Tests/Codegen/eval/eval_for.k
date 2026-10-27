// `eval for` (EVAL.md §5): a range with eval bounds (also signed, also a
// generic value parameter's), an eval array, or an eval generator, always
// unrolled as a pack expansion, so in each copy the binding is a constant
// (an `eval if` on it is C++ `if constexpr`). `continue` and `break` are
// the copy's, a `while` inside keeps its own `break`. Inside an `eval fn`
// an `eval for` is an ordinary loop (its bounds may be parameters).
eval PRIMES = [2, 3, 5, 7]
eval N = 6

eval fn evens(n: i32) -> yield i32 {
    for var k: i32 = 0; k < n; ++k {
        if k % 2 == 0 { yield k }
    }
}

eval fn sum_range(n: i32) -> i32 {
    var total = 0
    eval for i in 1..=n { total += i }
    return total
}
eval S = sum_range(4)

fn first_over(limit: i32) -> i32 {
    eval for p in PRIMES {
        if p > limit { return p }
    }
    return -1
}

fn <eval M: usize> count() -> usize {
    var c: usize = 0
    eval for i in 0..M { c += 1 }
    return c
}

fn main() -> i32 {
    var s = 0
    eval for i in 0..N {
        if i == 2 { continue }
        if i == 5 { break }
        eval if i == 3 { s += 100 } else { s += i }
    }
    // 0 + 1 + 100 + 4 = 105
    var g = 0
    eval for e in evens(9) { g += e }        // 0+2+4+6+8 = 20
    var neg = 0
    eval for i in -2..1 { neg += i }         // -2 -1 0 = -3
    return s + g + neg + first_over(4) + S + (count<3>() as i32) - 140   // 105+20-3+5+10+3-140 = 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The eval generator returns its compile-time buffer; main's loops are
// folds over an index pack, not runtime loops.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}eval_for.k
// IR:     consteval::__kairo_eval_buf<signed int> evens(signed int n) noexcept {
// IR:     __kairo_y.push(k);
// IR:     int main() noexcept {
// IR:     (... &&[&]<decltype(sizeof(0)) __kairo_I0>()->bool {
// IR-NEXT:    {{\[\[}}maybe_unused{{\]\]}} constexpr signed int i = static_cast<signed int>((0) + static_cast<signed int>(__kairo_I0));
// IR:     return true;
// IR:     if constexpr(i == 3) {
// IR:     (__make_integer_seq< ::__kairo_iseq, decltype(sizeof(0)), static_cast<decltype(sizeof(0))>(( ::eval_for::N) -(0))> {
// IR:     static constexpr decltype(sizeof(0)) __kairo_egn0 =( ::eval_for::evens(9)).n;
// IR:     {{\[\[}}maybe_unused{{\]\]}} constexpr signed int e = __kairo_eg0.v[__kairo_I0];

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0

// Every literal kind with a compile-time C++ form is eval-able (EVAL.md §2):
// integers of every width and suffix, floats, bool, char, arrays and
// tuples, each a `constexpr` constant. Strings, vectors, sets and maps are
// SC116E until they have one (Tests/Sema/Eval/eval_literal_gaps.k).
eval I8: i8 = -128
eval U64: u64 = 18446744073709551615u64
eval I128: i128 = 170141183460469231731687303715884105727
eval F32: f32 = 1.5
eval F64 = 2.25
eval B = true
eval C = 'K'
eval ARR = [2, 3, 5, 7]
eval GRID: [[i32; 2]; 2] = [[1, 2], [3, 4]]
eval TUP = (1, 2.5, false)

fn main() -> i32 {
    var r = 0
    if I8 == -128 { r += 1 }
    if U64 == 18446744073709551615u64 { r += 1 }
    if I128 > 0 { r += 1 }
    if F32 == 1.5 { r += 1 }
    if F64 == 2.25 { r += 1 }
    if B { r += 1 }
    if C == 'K' { r += 1 }
    r += ARR[3] + GRID[1][0] + TUP.0          // 7 + 7 + 3 + 1
    if !TUP.2 { r += 1 }
    return r                                   // 8 + 11 == 19
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: constexpr signed char const I8 =
// IR: constexpr float const F32 =
// IR: constexpr signed int const ARR[4] =
// IR: constexpr::builtin::Tuple3<signed int, double, bool> const TUP =

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 19

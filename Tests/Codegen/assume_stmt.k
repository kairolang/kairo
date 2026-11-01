// `@assume(c)` is a statement of its own: clang's `__builtin_assume(c)` at
// that point, so the optimizer may take `c` as true from there on (a false
// one is undefined behavior). It does not attach to anything: it sits alone
// on its line, in a function body, wherever a statement can.

fn div_by(n: i32, d: i32) -> i32 {
    @assume(d > 0)
    return n / d
}

fn sum_to(n: i32) -> i32 {
    var s = 0
    @assume(n >= 0)
    for var i = 0; i < n; ++i {
        @assume(i < n);
        s += i
    }
    return s
}

fn main() -> i32 {
    if div_by(10, 2) != 5 { return 1 }
    if sum_to(4) != 6 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}assume_stmt.k
// CXX: __builtin_assume(
// CXX: __builtin_assume(
// CXX: __builtin_assume(
// CXX-NOT: kairo_rt_assume(
// CXX: int main(

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu --cache-dir %t.d/ir
// RUN: %FileCheck %s --check-prefix=IR < %t.d/ir/assume_stmt.ll
// IR-LABEL: define {{.*}}@_ZN11assume_stmt6div_byEii(
// IR: call void @llvm.assume(i1

// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe

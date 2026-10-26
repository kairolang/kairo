// An initializer on an `eval` field (eval.mdx, Eval in Classes): the field
// is a static of the class, its value a compile-time constant (EVAL.md
// 1.2). The array-typed half of the same ticket is
// Tests/Codegen/eval/array_field_initializer.k (still XFAIL).

class C {
    pub eval K: i32 = 3
    pub var a: i32 = 4
}

fn main() -> i32 {
    var c = C()
    return C::K + c.a                           // 3 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: static const signed int K;
// IR: inline constexpr const signed int C::K = 3;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7

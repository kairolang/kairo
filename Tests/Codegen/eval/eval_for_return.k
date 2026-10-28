// A `return` out of an `eval for` copy (EVAL.md §5): the copy sets the
// function's flag and value slot and stops the fold; an inner expansion
// stops its enclosing copy, and the code after the outermost one returns.
// A `void` function's return carries no value.
fn find(target: i32) -> i32 {
    eval for i in 0..4 {
        eval for j in 0..4 {
            if (i * 4) + j == target { return (i * 10) + j }
        }
    }
    return -1
}
fn side() {
    eval for i in 0..3 { if i == 1 { return } }
}
fn main() -> i32 {
    side()
    var w = 0
    eval for i in 0..3 {
        var k = 0
        while k < 10 { k += 1  if k == 2 { break } }   // the while's own break
        w += k
    }
    return find(6) + w      // 12 + 6
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}eval_for_return.k
// IR:     bool __kairo_efr = false;
// IR-NEXT: signed int __kairo_efv {
// IR:     __kairo_efr = true;
// IR-NEXT: __kairo_efv =
// IR:     if(__kairo_efr) {
// IR-NEXT:    return false;
// IR:     if(__kairo_efr) {
// IR-NEXT:    return __kairo_efv;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 18

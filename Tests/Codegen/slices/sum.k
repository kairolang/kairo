// A slice literal is a Slice built over an array. As an argument the array is a
// prvalue that lives to the end of the full-expression; bound to a `var` it is
// a local in the var's scope. The exit code reads the first element and the
// length back through both.

fn head_plus_len(const xs: [i32;]) -> i32 {
    return (*(xs.data)) + (xs.len as i32)
}

fn extended() -> i32 {
    var s: [i32;] = [4, 5];
    return head_plus_len(s)
}

fn conditional(c: bool) -> i32 {
    return if c { head_plus_len([20, 1]) } else { 0 }
}

fn main() -> i32 {
    // (7 + 3) + (4 + 2) + (20 + 2) + 0 == 38
    return head_plus_len([7, 2, 3]) + extended() + conditional(true) + conditional(false)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The argument form is an array prvalue, never a hoisted temp; the `var` form
// is the one local this lowering mints.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// Bodies emit in source order: extended, conditional, main.
// IR: signed int __kairo_tmp0[2]
// IR: __kairo_array<signed int, 2>
// IR: __kairo_array<signed int, 3>
// IR-NOT: __kairo_tmp1

// REQUIRES: clang
// `-o` names a DIRECTORY: the entry TU's object, plus one per builtin TU
// it pulled in. The Slice instance is homed in whichever of those used it,
// so all of them go to the linker.
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 38


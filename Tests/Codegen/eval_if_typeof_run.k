// `eval if typeof T == U` (eval.md "Type-based branching", G67): the
// comparison of two types is a compile-time bool, and the unselected
// branches are not type-checked. Covered: a non-dependent condition (with
// `!`, `&&`, `!=`, a bare primitive operand) folded in Sema, whose untaken
// branches are type errors and are dropped, and the program running the
// taken one. The dependent (generic) form is
// Tests/Sema/Check/eval_if_typeof_dependent.k.
// Not covered: a member-name error (ChainBinding, R025E) in a NON-dependent
// untaken branch is still reported; type errors there are not.
// The diag block must stay empty: no SC094E / U001E on the comparison, no
// error from an unselected branch.

class A { pub var x: u32 = 0 }
class B { pub var y: u32 = 0 }

fn fixed() -> u32 {
    eval if typeof A == B {
        return "not a u32"
    } else if !(typeof A != A) && (typeof u32 == u32) {
        return 3
    } else {
        return A()
    }
}

fn main() -> i32 {
    if fixed() != 3 { return 1 }
    return 0
}

// --- lit wiring ---

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// DIAG-NOT: warning

// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 0

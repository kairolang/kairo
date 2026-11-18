// `eval if typeof T == U` over a generic parameter (eval.md "Type-based
// branching"): the branch is known per instance only, so the generic
// check reports nothing from any branch of it, here one per member set and a
// final branch invalid for every T. Fallback scope: the branches are typed
// with diagnostics dropped (ChainBinding and the typer), and nothing checks
// the branch an instance takes; codegen of such a branch fails today (a
// poisoned expression reaches EmitIR), so this is a type-check-only test.

class A { pub var x: u32 = 0 }
class B { pub var y: u32 = 0 }

fn <T> pick(v: T) -> u32 {
    eval if typeof T == A {
        return v.x + 10
    } else if typeof T == B {
        return v.y + 20
    } else if typeof T == i32 {
        return (v as u32) + 30
    } else {
        return v.missing
    }
}

fn main() -> i32 {
    var a = A()
    var i: i32 = 4
    return (pick(a) + pick(i)) as i32
}

// --- lit wiring ---

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// DIAG-NOT: warning

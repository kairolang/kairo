// A branch of an `eval if typeof T == U` over a generic parameter is typed
// once with its diagnostics held back (which branch runs is per instance).
// An error in it that was only dropped left a poisoned node, no diagnostic at
// type-check and an EmitIR ICE at -c. It is reported now. Here `usize > u32`
// has no common type.

ffi "c++" import "eval_if_dependent_branch_error.h"

class Table {
    const MAX: u32 = u32::MAX;
    var a: Arena;
    fn <T> create(self) -> u32 {
        eval if typeof T == i32 {
            if self.a.size() > self.MAX { return 1; }
            return 7
        }
        return 0
    }
}

fn main() -> i32 {
    var t = Table()
    return (t.create<i32>()) as i32
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: eval_if_dependent_branch_error.k:{{[0-9]+}}:{{[0-9]+}}: error [SC033E]: operands 'usize' and 'u32' do not unify

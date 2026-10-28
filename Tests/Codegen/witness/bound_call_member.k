// A member of a bound call's record result, `c.get(1).w`, where `get` is a
// requirement reached through `C impl PW<i32>` returning `Wrap<V>`
// (interfaces.mdx, Generic Bodies: a bound's requirement is called like a
// method, and its result is the requirement's return type at the bound's
// arguments).
//
// Overload resolution binds the requirement's interface parameters from the
// bound (V := i32), so the call types as Wrap<i32> and `.w` binds as on any
// Wrap<i32>. It used to type as unknown and ICE in EmitIR ("unbound member
// step reached codegen"); witness/composed_dependent_leaf.k still spells the
// typed-temporary form that worked around it.

pub struct <W> Wrap { pub var w: W }
pub interface <V> PW { fn get(const self, i: i32) -> Wrap<V> }
pub struct WB { pub var v: i32 }
extend WB {
    pub fn get(const self, i: i32) -> Wrap<i32> = Wrap<i32> { w: self.v + i }
}
pub fn <C impl PW<i32>> w(c: C) -> i32 { return c.get(1).w }

fn main() -> i32 {
    var x = WB { v: 3 }
    return w(x)                                 // 3 + 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4

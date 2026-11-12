// `op ->` may overload on receiver const-ness, as `op []` may
// (operator-overloading.mdx, "Const Overloading Operators";
// functions-overloading.mdx, the place-operator exemption). The
// pair is not R041E "class member 'op ->' cannot be redeclared". Here each
// overload points at a different field, so the result shows which one a
// const and a mutable receiver called: a write goes through the `self`
// one, a read through a const receiver the `const self` one.

class In { pub var v: i32 = 0 }

class Ptr {
    var w: In = In()
    var r: In = In()
    fn Ptr(self) { self.r.v = 30 }

    fn op -> (self) -> *In { return &self.w }
    fn op -> (const self) -> *const In { return &self.r }
}

fn rd(const p: Ptr) -> i32 { return p->v }

fn main() -> i32 {
    var p = Ptr()
    p->v = 4
    if p.w.v != 4 || p.r.v != 30 { return 1 }
    if rd(p) != 30 { return 2 }
    if p->v != 4 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe

// An argument for a parameter read through an associated type is checked
// against that type at the deduced arguments, and the reason names it.

interface Src {
    type Item
    fn get(self) -> Self::Item
}

class Num {
    pub var v: i32

    pub fn Num(self, v: i32) {
        self.v = v
    }
}

struct Count {
    pub var n: i32
}

extend Count impl Src {
    type Item = Num
    fn get(self) -> Num { return Num(self.n) }
}

fn <J impl Src> first(j: J, v: J::Item) -> i32 {
    return 1
}

fn main() -> i32 {
    return first(Count { n: 0 }, true)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: assoc_param_mismatch.k:31:12: error [SC063E]: no matching overload for call to 'first'
// CHECK: assoc_param_mismatch.k:26:1: note [I900N]: candidate not viable: cannot convert argument of type 'bool' to parameter 'v' of type 'Num'

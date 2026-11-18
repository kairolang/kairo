// `v in self` in a generic class that declares no `op in` is SC066E at the
// definition, as in a concrete class; it used to pass type-checking and
// reach codegen as an internal error.
class <T> Bag {
    var flag: bool = false
    fn Bag(self) { }
    fn has(self, v: T) -> bool { return v in self }
}

fn main() -> i32 {
    var b = Bag<i32>()
    return b.has(1) as i32
}

// --- lit wiring ---
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --implicit-check-not=I003E --implicit-check-not=internal
// CHECK: generic_in_without_op_in.k:7:41: error [SC066E]: 'in' needs an 'op in' on 'Bag<T>' taking a 'T'

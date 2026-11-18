// A constructor that does not write a field of type `K` before the object is
// used leaves it to its default, and an instance whose `K` has no default
// constructor cannot build it: the instance is rejected, not miscompiled.

class NoDef {
    pub var n: i32 = 0
    pub fn NoDef(self, n: i32) { self.n = n }
}

class <K> Reads {
    pub var key: K
    pub fn Reads(self, k: K) { var seen = self.key; self.key = k }
}

class <K> Leaves {
    pub var key: K
    pub fn Leaves(self) { }
}

fn main() -> i32 {
    var a = Reads<NoDef>(NoDef(1))
    var b = Leaves<NoDef>()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK: ctor_field_no_default_unwritten.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: no matching constructor for initialization of '{{.*}}NoDef'
// CHECK: ctor_field_no_default_unwritten.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: no matching constructor for initialization of '{{.*}}NoDef'
// RUN: not %kairo %s -o %t.exe --cache-dir %t.d

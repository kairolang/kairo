// A context binding `x as var r { }` is SC116E; it used to reach EmitIR as an
// internal error.
class Res {
    var v: i32
    fn Res(self, v: i32) { self.v = v }
}

fn make() -> Res { return Res(7) }

fn main() -> i32 {
    make() as var r {
        return r.v
    }
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --implicit-check-not=I003E --implicit-check-not=internal
// CHECK: context_binding_unsupported.k:11:5: error [SC116E]: a context binding ('as var') is not yet supported

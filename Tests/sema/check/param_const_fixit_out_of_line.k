// The "never mutated; declare it 'const'" fix-it on an out-of-line
// method's parameter must edit the definition and the declaration, or the definition
// stops matching its in-class declaration and C++ refuses it ("out-of-
// line definition ... does not match any declaration"). The fix-it
// adds `const` at the declaration too, with a note there.
class C {
    var n: usize = 0
    fn take(self, s: Big) -> usize
}

fn C::take(self, s: Big) -> usize {
    return s.n as usize + self.n
}

fn main() -> i32 {
    var c = C()
    return c.take(Big()) as i32
}

class Big { pub var n: i32 = 0; fn Big(self) { } @copy fn Big(self, const o: Self) { self.n = o.n } }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: param_const_fixit_out_of_line.k:11:18: warning [SC224W]: parameter 's' is never mutated; declare it 'const'
// CHECK-NEXT: fix-it:"{{.*}}param_const_fixit_out_of_line.k":{11:18-11:18}:"const "
// CHECK-NEXT: fix-it:"{{.*}}param_const_fixit_out_of_line.k":{8:19-8:19}:"const "
// CHECK-NEXT: param_const_fixit_out_of_line.k:8:19: note [I900N]: 's' is also declared here

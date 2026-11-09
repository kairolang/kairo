// `.0` on a tuple reached through a dependent receiver (CRTP
// `self.dyn()->sig()`) is left to each instance; TupleLowering spells it
// as the field `_0` and must not ICE on the unbound step.
pub class <T: type> Base {
    fn dyn(self) -> unsafe *T {
        return unsafe ((unsafe &self) as unsafe *T);
    }
    fn go(self) -> i32 {
        var r = self.dyn()->sig();
        var a = r.0;
        var b = r.1;
        if b { return a; }
        return 0;
    }
}
class D derives Base<D> {
    fn sig(self) -> (i32, bool) { return (7, true); }
}
fn main() -> i32 {
    var d = D{};
    if d.go() != 7 { return 1; }
    return 0;
}

// --- lit wiring ---
// RUN: { %kairo -fduck-generics %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: Internal Compiler Error
// RUN: rm -rf %t.d
// RUN: %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe

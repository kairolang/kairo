// Tuple index steps off a dependent receiver stay clean for each element
// position and for a three-element tuple; no internal error.
pub class <T: type> Base {
    fn dyn(self) -> unsafe *T {
        return unsafe ((unsafe &self) as unsafe *T);
    }
    fn go(self) -> i32 {
        var r = self.dyn()->sig();
        var a = r.0;
        var b = r.1;
        var c = r.2;
        if b { return a + c; }
        return 0;
    }
}
class D derives Base<D> {
    fn sig(self) -> (i32, bool, i32) { return (7, true, 2); }
}
fn main() -> i32 {
    var d = D{};
    if d.go() != 9 { return 1; }
    return 0;
}

// --- lit wiring ---
// RUN: rm -f %t.exe && rm -rf %t.d
// RUN: { %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='I003E' --implicit-check-not='internal' --implicit-check-not='error ['
// RUN: %t.exe

// In a duck <T: type> body, `b.first(2).note(3)` where `b` is deduced and `first`
// returns a pointer emitted `.note` on the pointer. The receiver is normalized to
// the object whichever the instance returns.

class Diag { fn report(self, n: i32) -> Builder { return Builder(n); } }
class Builder {
    pub var n: i32 = 0;
    fn Builder(self, n: i32) { self.n = n; }
    fn first(self, k: i32) -> unsafe *Builder { self.n += k; return unsafe (&self as unsafe *Builder); }
    fn note(self, k: i32) -> unsafe *Builder { self.n += k; return unsafe (&self as unsafe *Builder); }
    fn emit(self) { }
}
class Host derives Mixin<Host> {
    pub var diag: unsafe *Diag = &null;
}
class <T: type> Mixin {
    inline fn dyn(self) -> *T { return unsafe (&self as *T); }
    pub fn go(self) -> i32 {
        var b = self.dyn()->diag->report(1);
        b.first(2).note(3);
        self.dyn()->diag->report(1).first(2).note(3).emit();
        return b.n
    }
}
fn main() -> i32 { var h = Host(); var d = Diag(); h.diag = unsafe &d; return h.go() }

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: CL001E
// RUN: %t.exe; test $? -eq 6

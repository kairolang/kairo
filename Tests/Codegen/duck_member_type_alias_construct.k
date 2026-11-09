// A nested type of a duck `<T: type>` parameter (`T::Guard`) has no type
// until an instance names T. As a local's type, an alias body, and through the
// alias as a construction (`G(x)`) it is spelled `typename T::Guard` and clang
// resolves it per instance, instead of an "unresolved type reached codegen" ICE.

class Host derives Mixin<Host> {
    pub var pos: i32 = 0;
    class Guard {
        priv var _p: unsafe *Host;
        fn Guard(self, p: unsafe *Host) { self._p = p; p->pos = p->pos + 10; }
        fn op finally (self) { self._p->pos = self._p->pos + 1; }
    }
}

class <T: type> Mixin {
    inline fn dyn(self) -> unsafe *T { return unsafe ((unsafe &self) as unsafe *T); }
    pub fn ahead(self) -> bool {
        type G = T::Guard;
        var t = G(self.dyn());
        return self.dyn()->pos == 10;
    }
}

fn main() -> i32 {
    var h = Host();
    if !h.ahead() { return 1 }
    if h.pos != 11 { return 2 }
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: I011W
// DIAG-NOT: I003E
// RUN: %t.exe

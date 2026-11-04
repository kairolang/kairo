// O26: `m.flag != Kind::None`, where `m` is a `var m: T::Pending;` local of a
// duck `<T: type>` mixin, ICEd "unbound member step reached codegen". The
// member step is dependent and is emitted as written; the comparison with the
// enum constant is emitted as the C++ `!=` per instance.

enum Kind { None, Pub, Priv }

class Host derives Mixin<Host> {
    class Pending {
        pub var flag: Kind = Kind::None;
        pub var n: i32 = 0;
    }
    fn fill(self, p: unsafe *Pending) { (*p).flag = Kind::Pub; (*p).n = 5; }
}
class <T: type> Mixin {
    inline fn dyn(self) -> *T {
        return unsafe (&self as *T);
    }
    pub fn go(self) -> i32 {
        var m: T::Pending;
        self.dyn()->fill(unsafe &m);
        var has = m.flag != Kind::None;
        if has { return m.n }
        return 0
    }
}
fn main() -> i32 {
    var h = Host();
    return h.go()
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: I011W
// DIAG-NOT: I003E
// RUN: %t.exe; test $? -eq 5

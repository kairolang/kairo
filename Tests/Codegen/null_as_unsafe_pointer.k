// O28d: `&null as unsafe *T` was emitted `reinterpret_cast<T*>(nullptr)`,
// which C++ rejects (std::nullptr_t cannot be reinterpreted). The null
// pointer conversion is a static_cast.

class Base { pub var a: i32 = 0; }
class Deco {
    pub var n: i32 = 0;
    static fn create(n: i32, p: unsafe *Base) -> unsafe *Deco {
        if p == &null { return &null; }
        return &null;
    }
}
class <T: type> Mix {
    inline fn dyn(self) -> *T { return unsafe (&self as *T); }
    pub fn go(self) -> i32 {
        var d: unsafe *Deco = Deco::create(self.dyn()->k(), unsafe (&null as unsafe *Base));
        if d == &null { return 3 }
        return 0
    }
}
class H derives Mix<H> { fn k(self) -> i32 { return 1 } }
fn main() -> i32 { var h = H(); return h.go() }

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: CL001E
// DIAG-NOT: I003E
// RUN: %t.exe; test $? -eq 3

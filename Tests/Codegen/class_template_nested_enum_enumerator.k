// O27: an enumerator of an enum nested in a class template, named inside the
// template's own members, is spelled over the template's parameters
// (`::stem::G<T>::E::B`); the argument-less `::stem::G::E::B` is a clang
// "use of class template requires template arguments".
class <T: type> G {
    enum E derives u8 { A, B }
    static fn s() -> i32 { return 1; }
    fn h(self, e: Self::E) -> i32 { return 0; }
    fn f(self) -> i32 { return self.h(Self::E::B) + G::s() - 1; }
}
fn main() -> i32 {
    var g = G<i32>();
    return g.f();
}

// --- lit wiring ---
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: %t.exe
// DIAG-NOT: CL001E

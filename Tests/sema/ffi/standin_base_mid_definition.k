// RUN: rm -rf %t.d
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
//
// A C++ container of a Kairo class whose pointer-field chain leads back to
// a class deriving a base that is still being defined (DeclContext holds
// `*Decl`, Decl holds `*TU`, TU derives DeclContext). The stand-in for the
// half-defined base is refused without a diagnostic: no location-less
// CL001E "base class has incomplete type", and the classes still compile
// and run.

ffi "c++" import "vector";

pub class DeclContext {
    pub var first: *Decl? = null
    pub var n: i32 = 0
}
pub class Decl {
    pub var tu: *TU? = null
    pub var id: i32 = 1
}
pub class TU derives DeclContext {
    pub var top: *Decl? = null
}

fn main() -> i32 {
    var a = cxx::std::vector<Decl>()
    var b = cxx::std::vector<TU>()
    var c = cxx::std::vector<DeclContext>()
    a.reserve(4)
    b.reserve(2)
    var t = TU()
    t.n = 7
    return t.n
}

// DIAG-NOT: error
// DIAG-NOT: CL001E

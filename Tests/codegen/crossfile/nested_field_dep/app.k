import lib::*

ffi "c++" import "vector"

// A struct nested in a class is defined inside the class's body, so a
// by-value field of an imported class in it needs that class complete
// before the OUTER class. The plan saw only the outer's own fields (here a
// vector of the nested struct), put the outer first, and clang reported
// "field has incomplete type" at the nested struct's field.
pub class Eng {
    struct Entry {
        var scope: Rng;
    }
    priv var es: cxx::std::vector<Self::Entry>;
    fn f(self) -> i32 { return 3; }
}

fn main() -> i32 {
    var e = Eng()
    return e.f()
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3

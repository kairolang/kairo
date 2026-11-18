// A false `assert static` in a generic body is that instance's error, not an ICE.

ffi "c++" import "type_traits";

struct NoDef { var x: i32; fn NoDef(self, v: i32) { self.x = v; } }

fn <T> mk() -> i32 {
    assert static cxx::std::is_default_constructible<T>::value, "T must be default-constructible";
    return 1;
}

fn main() -> i32 {
    return mk<NoDef>();
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -o %t.exe 2>&1 || true; } | %FileCheck %s
// CHECK: T must be default-constructible

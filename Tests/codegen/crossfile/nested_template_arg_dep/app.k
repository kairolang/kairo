import lib::*

// `Outer::Inner` as an argument of a template that holds it only by
// pointer. Outer was admitted at forward strength (the argument is not by
// value), yet C++ needs it complete to resolve the nested-name-specifier:
// clang reported "incomplete type 'Outer' named in nested name specifier".
fn main() -> i32 {
    var n = Ni()
    return n.z
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 2

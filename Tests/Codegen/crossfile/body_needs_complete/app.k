import writer::*
import nodes::*

// O36: a body that uses a class only through a pointer or a template
// argument still needs it COMPLETE in its TU when it converts the pointer
// to a base, reads a base member through it, destroys a std container of
// it, or instantiates a function template at it. Each used to be admitted
// at forward strength, so clang saw `class Sub;` alone.
fn main() -> i32 {
    var s = Sub()
    var p: unsafe *Sub = unsafe (&s)
    var b: unsafe *Base = up(p)
    return b->k + inherited(p) + drop_holder() + tagged(b)
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5

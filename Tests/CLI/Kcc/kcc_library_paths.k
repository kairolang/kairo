// Separate compilation from INSIDE a library. Inputs/libpath/geometry/module.k
// pins `module geo`, so x.k is `geo::inner::x` and shapes.k `geo::shapes`
// whatever directory kcc runs in: the module path is found by walking up from
// the file to its pin (IMPORTS.md §2.1), not from the cwd down. Each object
// below is built from a different cwd -- inside the library, outside every
// search root, above the library -- and they link, because all three runs
// agree on every name. With the walk stopping at the cwd, x.o defined `x::f`
// and shapes.o `shapes::area`, and the link failed on main.o's
// `geo::inner::x::f`. 40 + 1 + 1.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/libpath/geometry/inner && %kcc -c x.k -o %t.d/x.o
// RUN: cd %t.d && %kcc -c %S/Inputs/libpath/geometry/shapes.k -o %t.d/shapes.o
// RUN: cd %S/Inputs/libpath && %kcc -c main.k -o %t.d/main.o
// RUN: %kcc %t.d/main.o %t.d/x.o %t.d/shapes.o -o %t.d/app && %t.d/app; test $? -eq 42

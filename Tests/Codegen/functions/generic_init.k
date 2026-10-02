// generic_init.k -- exit 7
struct <T> Box { var v: T; var n: i32; }

fn <T> boxed(x: T) -> Box<T> { return Box<T> { v: x, n: 1 }; }

fn main() -> i32 {
    var b = boxed(6);
    return b.v + b.n;
}

// --- lit wiring -----------------------------------------------------------
// A named initializer of a DEPENDENT record (`Box<T> { ... }` in a generic
// body) is typed with that record, not left unknown, so EmitIR spells it as
// a designated initializer instead of ICEing on an untyped node. The
// explicit instantiation parenthesizes its declarator-id: unparenthesized,
// `Box<signed int> ::generic_init::boxed` lexes as one nested-name-specifier
// and clang looks for a member `generic_init` inside Box<signed int>.

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      template<class T>::generic_init::Box<T> boxed(T x) {
// CXX-NEXT: return::generic_init::Box<T> {
// CXX-NEXT: .v = x,.n = 1
// CXX:      template::generic_init::Box<signed int>({{ *}}::generic_init::boxed<signed int>)(signed int);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 7

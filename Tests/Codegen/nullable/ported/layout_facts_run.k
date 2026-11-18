// Run: the layout the documentation promises for a nullable, each case
// citing its line. A nullable safe pointer is the pointer alone
// (c-cpp-exposing.mdx, nullables across the boundary: "`*T?` (any safe
// pointer, `const` included) | the pointer alone"; nullables.mdx, Nullable
// Types: "A nullable safe pointer is the pointer itself, the same size"); a
// nullable closed enum is the enum alone (same pages, and enums-adt.mdx,
// Memory layout: `Color?` is one byte for `enum Color derives u8`); `bool?`
// is two bytes (nullables.mdx: "`bool?` is two bytes"; the one-byte form is
// planned); any other `T?` stores the value and a presence flag, so it is
// larger than `T`. The exit status is the number of the first failing case.

enum Color derives u8 { Red, Green, Blue }
class Foo { pub var a: i32 = 1; pub fn Foo(self) { } }
struct Pair { pub var a: i32; pub var b: i32 }

fn main() -> i32 {
    if sizeof *i32? != sizeof *i32 { return 1 }
    if sizeof *const i32? != sizeof *const i32 { return 2 }
    if sizeof *Foo? != sizeof *Foo { return 3 }
    if sizeof *u8? != sizeof *u8 { return 4 }
    if sizeof *Pair? != sizeof *Pair { return 5 }
    if sizeof *Color? != sizeof *Color { return 6 }
    if sizeof Color? != sizeof Color { return 7 }
    if sizeof Color? != 1 { return 8 }
    if sizeof bool? != 2 { return 9 }
    if sizeof i32? <= sizeof i32 { return 10 }
    if sizeof u8? <= sizeof u8 { return 11 }
    if sizeof i64? <= sizeof i64 { return 12 }
    if sizeof f64? <= sizeof f64 { return 13 }
    if sizeof Pair? <= sizeof Pair { return 14 }
    if sizeof Foo? <= sizeof Foo { return 15 }
    if sizeof *i32? != sizeof usize { return 16 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error [' --implicit-check-not='warning ['

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe

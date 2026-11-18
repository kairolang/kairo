// `v as E?` from an integer into a nullable closed enum, and `e as u8?`
// back. The cast is to the inner type, then the implicit conversion
// to the nullable: C++'s Nullable<E> has no constructor from E's integer,
// so a one-step static_cast would be a clang error
// (CL001E "no matching conversion for static_cast"). The closed enum's
// run-time check still runs first: a value no variant has crashes (status
// 134), it does not become null.

import std::io::println

enum Color derives u8 { Red, Green, Blue }

fn mc(v: u8) -> Color? = v as Color?
fn back(c: Color) -> u8? = c as u8?

fn main() -> i32 {
    var r = 0
    var g = mc(1)
    if g? && ((g ?? Color::Red) == Color::Green) { r += 1 }
    var b = back(Color::Blue)
    if b? && ((b ?? 0) == 2) { r += 2 }
    println(f"ok {r}")
    var bad = mc(7)
    println("not reached")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR --match-full-lines < %t.err
// OUT:      ok 3
// OUT-NOT:  not reached
// ERR:      v as Color?: the value is no variant of the closed enum 'Color' at {{.*}}nullable_enum_cast.k:13:26

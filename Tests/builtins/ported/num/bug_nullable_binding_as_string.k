// XFAIL: *
// `x as string` on a `var x? = ...` binding that `if x?` has narrowed to non-null is rejected
// by the C++ stage (CL001E: static_cast from `Null<T> *` to `const T *`), though the checks
// accept it: nullables.mdx, Narrowing, says a known non-null nullable "is used as its `T`
// directly, with no syntax at the use", and lists `as string` among operators on a value.
// `f"{x}"` and `x.append_to(&s)` on the same binding compile.

import std::io

fn main() -> i32 {
    var err = ParseError { at: 0, kind: ParseErrorKind::None }
    var r?  = i32::from_str("12", &err)
    if r? {
        var by = r as string
        io::println(by)
    }

    var f? = f64::from_str("2.5", &err)
    if f? {
        var by = f as string
        io::println(by)
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: 12
// CHECK: 2.5

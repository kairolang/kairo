// A namespace-scope initializer whose lowering is a statement expression:
// `unwrap!(e)` and the checked `as` into a closed enum. C++
// allows no `({ ... })` at namespace scope (CL001E "statement expression not
// allowed at file scope"), so there the block is the body of a lambda called
// on the spot. The checks still run, before main: the second program's
// unwrap of null crashes at startup.

enum Color derives u8 { Red, Green, Blue }

fn one() -> i32? = 1
fn two() -> u8 { return 2 }

var a = unwrap!(one())
var c: Color = two() as Color
var d = (two() as Color) as u8

fn main() -> i32 {
    var r = a
    if c == Color::Blue { r += 2 }
    if d == 2 { r += 4 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d %t.n
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
// RUN: printf 'fn none() -> i32? { return null }\nvar z = unwrap!(none())\nfn main() -> i32 { return z }\n' > %t.null.k
// RUN: %kairo %t.null.k -o %t.null.exe --cache-dir %t.n
// RUN: %t.null.exe 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=ERR < %t.err
// ERR: unwrap!(none()) on null at {{.*}}.null.k:2:9

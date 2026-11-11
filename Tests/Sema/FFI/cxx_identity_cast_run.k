// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=WARN
// RUN: %t.exe; test $? -eq 7
// `s as S` on a value already of the C++ record type S is the identity
// (SC031W says so); it is not an I003E in EmitIR ("`as` on a record value").
// The cast is a no-op that yields the value, so the result is S's own copy.
// WARN: warning [SC031W]: redundant cast
ffi "c++" import "cxx_identity_cast_run.h"

fn main() -> i32 {
    var s = IdS()
    var t = s as IdS
    var b = IdBag(4)
    var c = b as IdBag
    // `c` is one copy of `b`, not two: size() is 4 + 100, so 104 - 100 = 4
    return t.v + (c.size() - 100) - 0
}

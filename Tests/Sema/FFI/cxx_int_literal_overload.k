// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 1
// An imported overload set is ranked as C++ ranks it, and to C++ an
// unsuffixed `7` is an int: `f(int)` is the identity, every other overload a
// conversion. It is not SC064E ambiguous. cxx_int_literal_overload_ambig.k: with
// no `int` overload C++ is ambiguous too, and so is Kairo.
ffi "c++" import "cxx_int_literal_overload.h"

fn main() -> i32 {
    return f(7)
}

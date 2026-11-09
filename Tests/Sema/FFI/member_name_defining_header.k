// A member of a class template declared in one header and defined in
// another (libc++'s <__fwd/string.h> and <string>) is named from the
// defining header's table. Read from the forward declaration's, `npos` came
// out as `cend`: "call to non-static member function without an object".
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0

ffi "c++" import "Inputs/o40/top.h"

fn main() -> i32 {
    var s = q::S();
    var ok = q::S::npos == s.find();
    return (if ok => 0 else => 1);
}

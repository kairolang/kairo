// RUN: %kairo %s --type-check-only
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
// A header typedef named like a builtin (zlib's `typedef unsigned char
// Byte`) is not R016E at the import line, which would kill the whole header. A foreign
// collision is reported where the name is used (c-cpp-calling: R016E), and the
// header's own `Byte` signatures keep meaning the C typedef.
// header_typedef_builtin_name_use.k checks the bare use.
ffi "c" import "header_typedef_builtin_name.h"

fn main() -> i32 {
    return one() + (low(0x35u8) as i32)
}

// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
// P819b: `&null` (a bare `null` is a nullable's null, pointers.mdx) is a raw
// pointer, so it converts to a C function-pointer parameter type.
ffi "c" import "null_fn_pointer_arg.h"

fn main() -> i32 {
    var a = unsafe nfp_run(&null, 3)          // -1
    var b = unsafe nfp_run(nfp_twice, 4)      // 8
    return a + b
}

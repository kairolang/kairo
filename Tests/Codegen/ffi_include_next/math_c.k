// libc++'s <math.h> is a wrapper: it `#include_next`s the C library's
// math.h, which defines FP_NAN and the rest that its own fpclassify uses.
// Every TU in the graph re-includes this file's header set as text in
// codegen (only its own set is a PCH), and that wrapper once named the
// header by its absolute path. A header reached that way was found in no
// search dir, so its #include_next restarted from the first one, found
// libc++'s math.h again (already guarded) and never the C one: "use of
// undeclared identifier 'FP_NAN'" from builtin's TUs. HeaderSet::
// replay_include now spells a system header by name. math_cxx.k is the
// same through `ffi "c++"`.

ffi "c" import "math.h"

fn main() -> i32 {
    return sqrt(1764.0) as i32
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42

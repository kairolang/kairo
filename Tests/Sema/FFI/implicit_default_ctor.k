// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
//
// `Result()` finds the default constructor clang declares lazily: the import
// forces clang to declare a record's implicit special members before it reads
// them. It used to be SC063E with only the copy / move constructors as
// (non-viable) candidates.
// DIAG-NOT: error

ffi "c++" import "implicit_default_ctor.h"

fn main() -> i32 {
    var r = Result()
    return r.v.x
}

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
//
// usize / isize is C++'s size_t / ptrdiff_t, so between same-width C
// overloads it picks the one whose parameter IS that type, as clang does
// (`std::to_string(n)` with n: usize is `to_string(unsigned long)` on
// LP64). Both do not rank as a conversion and tie (SC064E).

ffi "c++" import "size_t_overload.h"
ffi "c++" import "string"

fn main() -> i32 {
    var n: usize = 42
    var d: isize = -1
    var s = cxx::std::to_string(n)
    var ok = (pick(n) == size_t_pick()) && (pick_signed(d) == ptrdiff_pick()) && (s.size() == 2)
    if ok { return 7 }
    return 1
}

// DIAG-NOT: error

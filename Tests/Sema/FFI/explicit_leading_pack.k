// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 13
//
// [temp.arg.explicit]/9: explicit template arguments fill the parameters in
// order, and a pack takes every one that is left; the parameters after it
// deduce from the call. `isa<T>(x)` against llvm's `template <typename...
// To, typename From>` was "'To' is a type pack, deduced from the arguments;
// it cannot be written as a generic argument yet".

// DIAG-NOT: error

ffi "c++" import "explicit_leading_pack.h"

fn main() -> i32 {
    var x: i32 = 1
    var r = 0
    if isa<i32>(x) { r += 1 }
    if isa<i8, i32>(x) { r += 2 }
    if isa<i8>(x) { r += 100 }
    // 0 + 1 + 2 = 3 explicit, so 3 + 10 = 13
    return r + 10 + count<i8>(x) - 1 + count<i8, i16, i32>(x) - 3
}

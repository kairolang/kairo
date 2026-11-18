// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
//
// `@cxx::delete v[i]` (was `delete v[i]`, 0.2.0) on a `vector<*T>`: the operand is the imported `T*&` that
// `operator[]` returns, read as its value, a pointer. It is not SC090E
// "'delete' requires a pointer, not 'unsafe *N&'".
//

// DIAG-NOT: error

ffi "c++" import "vector"
ffi "c++" import "delete_ref_operand.h"

struct N { var x: i32 = 0 }

fn main() -> i32 {
    var v: cxx::std::vector<unsafe *N>
    v.push_back(make_one<N>())
    @cxx::delete v[0];
    return 0
}

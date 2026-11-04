// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
//
// `delete v[i]` on a `vector<*T>`: the operand is the imported `T*&` that
// `operator[]` returns, read as its value, a pointer. It used to be SC090E
// "'delete' requires a pointer, not 'unsafe *N&'" (the migrated
// Location/SourceManager.k, self-host phase 5.2).

// DIAG-NOT: error

ffi "c++" import "vector"
ffi "c++" import "delete_ref_operand.h"

struct N { var x: i32 = 0 }

fn main() -> i32 {
    var v: cxx::std::vector<unsafe *N>
    v.push_back(make_one<N>())
    delete v[0];
    return 0
}

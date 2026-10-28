// libc++'s std::make_unique and std::make_shared beyond the one-object
// call Codegen/ffi_forwarding/std_make_unique.k covers: an array of
// unknown bound (`make_unique<T[]>(n)`, the overload that takes a count),
// a C++ record built from its constructor's arguments, a Kairo record, and
// make_shared, whose overloads are split the same way.

ffi "c++" import "memory"
ffi "c++" import "sfinae.h"

class Cp {
    pub var n: i32 = 0
    fn Cp(self, n: i32) { self.n = n }
}

fn main() -> i32 {
    var one = cxx::std::make_unique<i32>(5)
    var pr  = cxx::std::make_unique<Pair>(1, 2)
    var kp  = cxx::std::make_unique<Cp>(4)
    var arr = cxx::std::make_unique<IntArr>(3)     // value-initialized: all 0
    var sh  = cxx::std::make_shared<i32>(6)
    var shp = cxx::std::make_shared<Pair>(7, 8)
    var n: usize = 2
    var arr2 = cxx::std::make_unique<IntArr>(n)
    var r = *one + (*pr).a + (*pr).b + (*kp).n               // 5 + 1 + 2 + 4 = 12
    r += arr[0] + arr[2] + arr2[1]                     // 0
    r += *sh + (*shp).a + (*shp).b                         // 6 + 7 + 8 = 21
    return r                                           // 33
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 33

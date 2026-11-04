// SI1: an lvalue of an imported C++ record whose copy constructor is deleted
// is never copied: clang would reject the copy at codegen, so Sema does first.
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s

ffi "c++" import "Inputs/si1_noncopy.h"

fn main() -> i32 {
    var c = getnc()            // CHECK: noncopyable_copy_rejected.k:[[@LINE]]:13: error {{.*}}cannot copy a value of type 'NC'
    var b = take_nc(getnc())   // CHECK: noncopyable_copy_rejected.k:[[@LINE]]:21: error {{.*}}cannot copy a value of type 'NC'
    return 0
}

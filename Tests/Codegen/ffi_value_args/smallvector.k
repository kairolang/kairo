// llvm::SmallVector<T, N>, the other value-argument template Compiler/
// imports (8 files). Its push_back, size and operator[] live in BASES whose
// own arguments are values (`SmallVectorTemplateBase<T, bool>`, chosen by
// partial specialization on `is_trivially_copyable<T>::value`): each base
// is an instance reached through the import with an Integral argument,
// which TypeImport now maps instead of making the whole base opaque.
//
// Object only (-c): the out-of-line growth paths live in libLLVMSupport.

ffi "c++" import "llvm/ADT/SmallVector.h"

fn main() -> i32 {
    var v: llvm::SmallVector<i32, 4>
    v.push_back(4)
    v.push_back(5)
    var u: llvm::SmallVector<i32, 2>
    u.push_back(6)
    var w: llvm::SmallVector<llvm::SmallVector<i32, 2>, 2>
    w.push_back(u)
    return v[0] + v[1] + (v.size() as i32) + w[0][0]
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --ffi-include %S/../../../Lib/llvm-runtimes/llvm/include --ffi-include %S/../../../build/llvm/include 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o
// RUN: %kairo %s -c -o %t.o --cache-dir %t.d --ffi-include %S/../../../Lib/llvm-runtimes/llvm/include --ffi-include %S/../../../build/llvm/include
// RUN: test -s %t.o

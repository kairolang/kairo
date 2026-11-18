// With llvm/ADT/DenseSet.h imported beside the other ADT headers, the
// set's members are typed: inserting a string is SC063E and a `bool`
// result bound to a string is SC028E, while `insert(k)` with a u64 is
// accepted.

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "llvm/ADT/StringRef.h"

fn main() -> i32 {
    var s: llvm::DenseSet<u64>
    s.insert("x")
    var k: u64 = 7
    s.insert(k)
    var b: string = s.contains(k)
    return 0
}

// --- lit wiring ---
// The LLVM headers are the in-tree ones Compiler/ itself builds against.
// RUN: { %kairo %s --type-check-only --ffi-include %S/../../../Lib/llvm-runtimes/llvm/include --ffi-include %S/../../../build/llvm/include 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: llvm_adt_imports_reject.k:13:5: error [SC063E]: no matching overload for call to 'insert'
// CHECK: llvm_adt_imports_reject.k:16:21: error [SC028E]: cannot convert 'bool' to 'string'

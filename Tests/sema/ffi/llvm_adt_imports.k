// Every LLVM ADT header Compiler/ imports (grep `ffi "c++" import
// "llvm/ADT` there), imported into one set. llvm/ADT/DenseSet.h alone used
// to take the import down ("VirtualFileManager: Offset out of segment
// bounds", ffi_llvm_denseset.k); each of the others must keep importing
// beside it. llvm_adt_smoke.k USES them.

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/ADT/STLExtras.h"
ffi "c++" import "llvm/ADT/IntrusiveRefCntPtr.h"
ffi "c++" import "llvm/ADT/StringRef.h"
ffi "c++" import "llvm/ADT/SmallString.h"
ffi "c++" import "llvm/ADT/MapVector.h"
ffi "c++" import "llvm/ADT/Twine.h"
ffi "c++" import "llvm/ADT/iterator_range.h"
ffi "c++" import "llvm/ADT/StringExtras.h"
ffi "c++" import "llvm/ADT/ArrayRef.h"
ffi "c++" import "llvm/ADT/APSInt.h"
ffi "c++" import "llvm/ADT/APInt.h"
ffi "c++" import "llvm/ADT/APFloat.h"

fn main() -> i32 {
    var s: llvm::DenseSet<u64>
    var k: u64 = 7
    s.insert(k)
    var m: llvm::DenseMap<u32, i32>
    m[1] = 2
    var r: llvm::StringRef
    return (r.size() as i32) + m[1]
}

// --- lit wiring -----------------------------------------------------------
// The LLVM headers are the in-tree ones Compiler/ itself builds against.
// RUN: { %kairo %s --type-check-only --ffi-include %S/../../../Lib/llvm-runtimes/llvm/include --ffi-include %S/../../../build/llvm/include 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning|Internal Compiler Error}}

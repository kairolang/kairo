// Every LLVM ADT header Compiler/ imports (grep `ffi "c++" import
// "llvm/ADT` there), imported together and used in the shapes Compiler/
// uses them: maps and vectors of Kairo pointers, inline sizes as value
// arguments, a set probe. llvm/ADT/DenseSet.h alone used to ICE the import
// (ffi_llvm_denseset.k); the rest must keep importing alongside it.
//
// Object only (-c): linking needs libLLVMSupport, which a test has no
// business pulling in, but the emitted C++ is compiled against the real
// headers, so a spelling clang rejects still fails here.

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

class Node {
    pub var id: i32
    fn Node(self, id: i32) { self.id = id }
}

fn main() -> i32 {
    var n = Node(1)
    var m: llvm::DenseMap<u32, *Node>
    m[3] = &n
    var s: llvm::DenseSet<u64>
    s.insert(7)
    var v: llvm::SmallVector<*Node, 4>
    v.push_back(&n)
    var sm: llvm::StringMap<i32>
    var sv: llvm::SmallVector<i32, 8>
    sv.push_back(2)
    var mv: llvm::MapVector<i32, i32>
    mv[1] = 2
    var ap = llvm::APInt(32, 5)
    var r = 0
    if s.contains(7) { r += 1 }
    r += m[3]->id + v[0]->id + sv[0] + (sv.size() as i32) + (sm.size() as i32) + (mv.size() as i32)
    r += ap.getZExtValue() as i32
    return r
}

// --- lit wiring -----------------------------------------------------------
// The LLVM headers are the in-tree ones Compiler/ itself builds against.
// RUN: { %kairo %s --type-check-only --ffi-include %S/../../../Lib/llvm-runtimes/llvm/include --ffi-include %S/../../../build/llvm/include 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning|Internal Compiler Error}}

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o
// RUN: %kairo %s -c -o %t.o --cache-dir %t.d --ffi-include %S/../../../Lib/llvm-runtimes/llvm/include --ffi-include %S/../../../build/llvm/include
// RUN: test -s %t.o

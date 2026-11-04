// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// G56: a Kairo generic with a VALUE parameter (`class <eval N: usize>`) gets a
// C++ stand-in template with a non-type parameter, so a C++ template over an
// instance of it (a pointer to `TB<16>`, a tuple holding one) is filled and its
// members resolve. The field `[u32; N]` is substituted per instance.
//
// CHECK-NOT: error
ffi "c++" import "llvm/ADT/SmallVector.h";
class <eval N: usize> TB { var data: [u32; N] }
struct R { var a: u32 }
class C {
    var s: llvm::SmallVector<(unsafe *TB<16>, R), 4>
    var p: llvm::SmallVector<unsafe *TB<16>, 4>
    fn n(self) -> usize { return self.s.size() + self.p.size() }
}

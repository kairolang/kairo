// A literal two C++ overloads would each take through a different
// converting constructor: without -fcxx-implicit-conv the note lists both
// classes and names the flag; the cast picks one under any setting.
ffi "c++" import "cxx_implicit_conv_split.h"

fn main() -> i32 {
    var n = pick("x")
    return n + pick("y" as Q)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: cxx_implicit_conv_split_many.k:7:13: error [SC063E]: {{.*}}'pick'
// CHECK: note [{{[A-Z0-9]+}}]: C++ would convert the argument implicitly to one of 'P', 'Q'; Kairo applies no C++ implicit conversion unless -fcxx-implicit-conv is given: write the cast to the one you mean, or pass -fcxx-implicit-conv
// CHECK-NOT: cxx_implicit_conv_split_many.k:8:{{[0-9]+}}: error
// With the flag both rank as one user-defined conversion: ambiguous, as in C++.
// RUN: { %kairo %s --type-check-only -fcxx-implicit-conv 2>&1 || true; } | %FileCheck %s --check-prefix=AMB
// AMB: cxx_implicit_conv_split_many.k:7:13: error [SC064E]: call to 'pick' is ambiguous
// AMB-NOT: cxx_implicit_conv_split_many.k:8:{{[0-9]+}}: error

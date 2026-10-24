// witness/operator_ext/main.k -- exit 11
// Operators through a bound where ADL cannot help: P is declared in `pt`,
// its `op ==` and unary `op -` in an `impl` extend in `ext`, so the C++
// forwarders sit in ext's namespace, which ADL on a `pt::P` never searches.
// Through the witness the call is qualified and needs none. `!=` is derived
// from the bound's `op ==` (`!(a == b)`), as on a concrete type.
import same
import pt::P
import ext
fn main() -> i32 {
    return same::ne(P { v: 1 }, P { v: 2 }) + same::negeq(P { v: 2 }, P { v: -2 }) * 10
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}operator_ext/same.k
// CXX: if((!{{ ?}}::{{.*}}::Same_witness<T>::__kairo_op_eq(a, b)))
// CXX: Same_witness<T>::__kairo_op_eq({{.*}}Same_witness<T>::__kairo_op_minus(a), b)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 11

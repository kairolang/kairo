// A `requires` value predicate is evaluated by C++ (EVAL.md §8, E10): in a
// function's body as a static_assert -- once for a plain function, per
// instance for a generic one -- and on a generic record as a C++ `requires`
// on the template, so clang rejects a bad instance where it is named.
eval fn is_pow2(n: i32) -> bool { return (n > 0) && ((n & (n - 1)) == 0) }
class <T> SmallBuffer requires sizeof T <= 128 { pub var v: i32 }
fn <eval N: i32> aligned() -> i32 requires is_pow2(N) { return N }
fn fixed() -> i32 requires sizeof i64 == 8 { return 1 }

fn main() -> i32 {
    var s = SmallBuffer<[u8; 64]>()
    return aligned<8>() + fixed()               // 9
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}requires_predicates.k
// IR:     template<class T> requires(((sizeof(T)) <=(128))) class SmallBuffer {
// IR:     static_assert({{.*}}::is_pow2(N), "requires clause of 'aligned' not satisfied");
// IR:     static_assert((sizeof(signed long) == 8), "requires clause of 'fixed' not satisfied");

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9

// A bad instance and a failing predicate are clang's errors, at the
// Kairo use and predicate.
// RUN: sed -e 's/SmallBuffer<\[u8; 64\]>/SmallBuffer<[u8; 256]>/' -e 's/aligned<8>/aligned<6>/' %s > %t.bad.k
// RUN: rm -rf %t.e
// RUN: { %kairo %t.bad.k -o %t.bad --cache-dir %t.e 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD-DAG: error [CL001E]: constraints not satisfied for class template 'SmallBuffer' [with T = unsigned char[256]]
// BAD-DAG: note [I900N]: because '(sizeof(unsigned char[256])) <= (128)' (256 <= 128) evaluated to false
// BAD-DAG: error [CL001E]: static assertion failed due to requirement '{{.*}}is_pow2(6)': requires clause of 'aligned' not satisfied

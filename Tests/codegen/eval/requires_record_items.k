// A generic record's `requires` value predicate that names an eval fn or an
// eval constant. The template head is written before any of them is
// declared, so such a predicate is a static_assert in the record's body,
// evaluated per instance, with the items it names defined ahead of the
// record (EmitPlan's early items). The self-contained predicate stays on the
// head (requires_predicates.k).
eval fn is_pow2(n: i32) -> bool { return (n > 0) && ((n & (n - 1)) == 0) }
eval LIMIT: usize = 16
class <eval N: i32> Ring requires is_pow2(N) { pub var v: i32 }
class <T> Small requires sizeof T <= LIMIT { pub var v: i32 }
class <T, eval N: i32> Both requires sizeof T <= 8 && is_pow2(N) { pub var v: i32 }

fn main() -> i32 {
    var r = Ring<8>()
    var s = Small<[u8; 8]>()
    var b = Both<i32, 4>()
    return 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}requires_record_items.k
// IR:     class Ring {
// IR-NEXT: static_assert({{.*}}::is_pow2(N), "requires clause of 'Ring' not satisfied");
// IR:     class Small {
// IR-NEXT: static_assert({{.*}}<= {{.*}}::LIMIT{{.*}}, "requires clause of 'Small' not satisfied");
// IR:     requires(((sizeof(T)) <=(8))) class Both {
// IR-NEXT: static_assert({{.*}}::is_pow2(N), "requires clause of 'Both' not satisfied");

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7

// A bad instance is clang's error, at the predicate, with the Kairo use as
// the instantiation note.
// RUN: sed -e 's/Ring<8>/Ring<6>/' -e 's/Small<\[u8; 8\]>/Small<[u8; 64]>/' -e 's/Both<i32, 4>/Both<i32, 3>/' %s > %t.bad.k
// RUN: rm -rf %t.e
// RUN: { %kairo %t.bad.k -o %t.bad --cache-dir %t.e 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD-DAG: error [CL001E]: static assertion failed due to requirement '{{.*}}is_pow2(6)': requires clause of 'Ring' not satisfied
// BAD-DAG: error [CL001E]: static assertion failed due to requirement 'sizeof(unsigned char[64]) <= {{.*}}LIMIT': requires clause of 'Small' not satisfied
// BAD-DAG: error [CL001E]: static assertion failed due to requirement '{{.*}}is_pow2(3)': requires clause of 'Both' not satisfied

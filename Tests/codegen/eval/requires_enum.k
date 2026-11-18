// An enum's `requires` value predicate, as requires.mdx writes it:
// `enum <T> Compact requires sizeof T <= 8`. The clause did not parse on an
// enum, and Codegen spelled value predicates on a class, struct or union
// only, so every instance was accepted. An ADT enum is written as its
// layout record under the enum's own head: a self-contained predicate goes
// on that head, one naming an eval item is a static_assert at the top of
// the record's body, exactly as for a record (requires_record_items.k).
eval LIMIT: usize = 8
enum <T> Compact
  requires sizeof T <= 8 {
    Some { value: T },
    None,
}
enum <T> Bounded requires sizeof T <= LIMIT {
    Has { value: T },
    Empty,
}

fn main() -> i32 {
    var c = Compact<i64>::None
    var b = Bounded<[u8; 8]>::Empty
    return 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}requires_enum.k
// IR:      requires(((sizeof(T)) <=(8))) struct Compact {
// IR:      struct Bounded {
// IR-NEXT: static_assert({{.*}}<= {{.*}}::LIMIT{{.*}}, "requires clause of 'Bounded' not satisfied");

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7

// A bad instance is clang's error, at the predicate.
// RUN: sed -e 's/Compact<i64>/Compact<[u8; 64]>/' -e 's/Bounded<\[u8; 8\]>/Bounded<[u8; 64]>/' %s > %t.bad.k
// RUN: rm -rf %t.e
// RUN: { %kairo %t.bad.k -o %t.bad --cache-dir %t.e 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD-DAG: error [CL001E]: constraints not satisfied for class template 'Compact'
// BAD-DAG: error [CL001E]: static assertion failed due to requirement 'sizeof(unsigned char[64]) <= {{.*}}LIMIT': requires clause of 'Bounded' not satisfied

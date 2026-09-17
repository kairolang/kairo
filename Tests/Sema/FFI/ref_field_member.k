// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Member lookup through a REFERENCE-typed imported field. libc++'s
// `vector::__destroy_vector` holds `vector& __vec_`; the member step peels
// the reference before the separator rules, so `.size()` answers as a member
// of `vector`. The Kairo-side cases (no libc++) are ref_receiver.k.

ffi "c++" import "vector"

fn destroy(d: *cxx::std::vector<i32>::__destroy_vector) -> u64 {
    return d->__vec_.size()
}

// DIAG-NOT: error

// SEMA: member .size @ 12:{{[0-9]+}} -> fn size @ {{.*}}[member of vector]

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Nested types of a libc++ instance -- a header this tree does not control.
// `value_type` is a member typedef; `__destroy_vector` is a real nested
// CLASS of `std::vector` (libc++ __vector/vector.h), declared-only by the
// implicit instantiation until the fill completes it. Its (private) field
// `__vec_` must bind. Access is not checked for imported members yet.
// (`__vec_` is a `vector&`; calling through it is ref_field_member.k.)

ffi "c++" import "vector"

fn value_type() -> i32 {
    var x: cxx::std::vector<i32>::value_type = 1
    return x
}

fn destroy(d: *cxx::std::vector<i32>::__destroy_vector) {
    d->__vec_
}

// DIAG-NOT: error

// SEMA:      member ->__vec_ @ 19:{{[0-9]+}} -> field __vec_ @ {{[0-9]+:[0-9]+}} [member of __destroy_vector]
// SEMA:      NamedIdentExpr @ 15:12 : i32
// SEMA:      0 unknown, 0 errored

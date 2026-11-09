// RUN: { %kairo %S/first.k %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// first.k is checked ahead of this file and its set imports <utility>
// first, so `std::move` is that set's -- a set that never includes err.h.
// There `std::move(e)` could spell `Err` only as an opaque blob, so the
// return type clang substitutes (`remove_reference_t<T>&&`) was never
// imported: the call typed as `<ffi type>&&` and `consume` had no overload
// (SC063E). Deduction now retries in this TU's own set.
// CHECK-NOT: error

ffi "c++" import "utility"
ffi "c++" import "err.h"

fn take(@move e: eh::Err) -> i32 {
    return eh::consume(cxx::std::move(e))
}

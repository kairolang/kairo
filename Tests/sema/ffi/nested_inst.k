// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// An imported-template instance whose ARGUMENT is another one. Filling
// `cont<cont<i32>>` means spelling `cont<i32>` as a clang type first, which
// is itself a specialization (TypeExport's recursion). `push` then takes
// `const cont<i32>&`, and the Kairo `cont<i32>` must be the same instance
// clang's parameter type imports as -- default argument included.

ffi "c++" import "traits_typedef.h"

fn use_nested() -> u64 {
    var c: cont<cont<i32>>
    var inner: cont<i32>
    c.push(inner)
    return c.size()
}

// `push(inner)` type-checks only if clang's `const cont<int, alloc>&` and
// the Kairo `cont<i32>` are one registry instance.
// DIAG-NOT: error

// Bound names and traits_typedef.h's lines, as in traits_typedef.k.
// SEMA:      member  .push  {{.*}} -> fn push @ 14:5  [member of cont]  [filled by clang, 16 bytes, align 8]
// SEMA:      member  .size  {{.*}} -> fn size @ 13:5  [member of cont]  [filled by clang, 16 bytes, align 8]
// SEMA:      0 unknown, 0 errored
// SEMA:      0 of them dependent, 0 errored

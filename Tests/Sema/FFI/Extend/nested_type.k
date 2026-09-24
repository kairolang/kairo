// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// A member TYPE of the extended instance, named from inside the extension:
// bare (`size_type`, found through the extended type as in a class body)
// and qualified (`Self::size_type`). Both must be clang's `unsigned long`,
// not the pattern's dependent `typename traits<A>::size_type`: the instance
// is filled before either lookup reads its table. Before that, bare was an
// R021E and `Self::` was an opaque `<ffi type>` that no u64 converted to.

ffi "c++" import "../traits_typedef.h"

extend cont<i32> {
    fn bare(self) -> size_type { return self.size() }
    fn qualified(self) -> Self::size_type { return self.size() }
}

fn use() -> u64 {
    var a: cont<i32>
    return a.bare() + a.qualified()
}

// DIAG-NOT: error

// SEMA:      <tu>::use
// SEMA:      CallExpr @ 20:12 : u64
// SEMA:      CallExpr @ 20:23 : u64
// SEMA:      0 unknown, 0 errored
// SEMA:      0 of them dependent, 0 errored

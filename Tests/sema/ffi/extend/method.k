// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// `extend` on an instance of an IMPORTED template adds Kairo methods beside
// clang's. Inside the body, `self.size()` reads the clang-filled instance;
// outside, one lookup through `a.` sees both kinds, and an extension method
// can call another.

ffi "c++" import "../traits_typedef.h"

extend cont<i32> {
    fn doubled(self) -> u64 { return self.size() * 2 }
    fn quadrupled(self) -> u64 { return self.doubled() * 2 }
}

fn use() -> u64 {
    var a: cont<i32>
    a.push(1)
    return a.quadrupled()
}

// DIAG-NOT: error

// SEMA:      member  .size {{.*}} -> fn size @ {{[0-9]+:[0-9]+}}  [member of cont]  [filled by clang
// SEMA:      member  .doubled @ 13:46 -> fn doubled @ 12:5  [member of cont]
// SEMA:      member  .push {{.*}} -> fn push @ {{[0-9]+:[0-9]+}}  [member of cont]  [filled by clang
// SEMA:      member  .quadrupled @ 19:14 -> fn quadrupled @ 13:5  [member of cont]
// SEMA:      0 unknown, 0 errored
// SEMA:      0 of them dependent, 0 errored

// RUN: rm -f %t.exe
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
// An imported overload whose enable_if conditions all hold beats one with
// none, an overload whose condition is false is no candidate, and a better
// conversion still wins first, as in clang.
// TC-NOT: SC064E
// TC-NOT: error
ffi "c++" import "cxx_enable_if_overload.h"

fn main() -> i32 {
    var n: i32 = 7
    if pick(n) != 2 {
        return 1
    }

    if only_false(n) != 1 {
        return 2
    }

    if ranked(n) != 1 {
        return 3
    }

    if conv(n) != 5 {
        return 4
    }

    var buf: [u8; 4] = [1, 2, 3, 4]
    var unsafe *base = unsafe (&buf as unsafe *const u8)
    var unsafe *p    = find_byte(unsafe (base as unsafe *const void), 2, 4)
    if unsafe (p as unsafe *const u8) != unsafe (base + 1) {
        return 5
    }

    return 0
}

// A value-initialised local of a hidden-tag type (`struct ::stat`,
// MMapRegion's `kairo::posix_stat()`) was emitted as `struct::stat()`, which
// is no expression ("expected expression"); an elaborated type specifier is
// not a simple-type-specifier. The head is spelled `__typeof__(struct ::stat)`.
ffi "c++" import "ffi_hidden_tag_value_init.h"

fn main() -> i32 {
    var t: tagval_t = tagval_t()
    t.a = 3
    t.b = 4
    return t.a + t.b - 7
}

// --- lit wiring ---
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: %t.exe
// DIAG-NOT: CL001E

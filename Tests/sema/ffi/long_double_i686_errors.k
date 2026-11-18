// The imported `long double` parameter is typed f80 on i686, so a string is
// not convertible to it: the candidate note names the parameter's type.

ffi "c++" import "long_double_i686.h"

fn main() -> i32 {
    var s: string = "x"
    var y: f80 = twice_ld(s)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-i686-linux-musl
// RUN: { %kairo %s --target=i686-linux-musl --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: long_double_i686_errors.k:8:18: error [SC063E]: no matching overload for call to 'twice_ld'
// CHECK: note [I900N]: candidate not viable: cannot convert argument of type 'string' to parameter 'v' of type 'f80'

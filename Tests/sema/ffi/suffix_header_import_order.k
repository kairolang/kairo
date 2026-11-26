// A header spelling is matched to its include by path suffix: "time.h" also
// ends ".../sys/time.h". Importing "sys/time.h" first must not capture the
// closure of "time.h", whose own names (`daylight`) have to fold.

ffi "c++" import "sys/time.h"
ffi "c++" import "time.h"

fn main() -> i32 {
    var d = daylight
    var tv: timeval
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not=error
// CHECK-NOT: R020E

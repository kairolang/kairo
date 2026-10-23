// Control: a header that builds imports cleanly, with no diagnostic. Log
// lines are not asserted on: debug and release stream different levels.

ffi "c++" import "ok.h"

fn f() -> i32 {
    return hd_ok(1);
}

// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT:  {{error|warning}} [

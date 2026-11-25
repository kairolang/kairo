// An `assert` message is a `string`: one that does not convert is an error
// at the message, not a C++ error after it.

fn check(v: i32) {
    assert v > 0, 5
    assert v > 1, "fine"
}

fn main() -> i32 {
    check(1)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: assert_message_not_string.k:5:19: error [SC028E]: cannot convert '{{.*}}' to 'string'
// CHECK-NOT: error

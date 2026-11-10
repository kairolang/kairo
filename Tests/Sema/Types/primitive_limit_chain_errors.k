// P754, the error side: a limit the type does not have is refused at the
// head of a longer chain as it is alone, once, at the limit (the step after
// it is not reported against a poisoned base).

extend bool {
    fn flip(const self) -> bool {
        return !self
    }
}

fn main() -> i32 {
    var z = bool::MAX.flip()
    var w = f8e4m3::INFINITY.is_nan()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: primitive_limit_chain_errors.k:12:13: error [R024E]: 'bool' has no 'MAX'
// CHECK: primitive_limit_chain_errors.k:13:13: error [R024E]: 'f8e4m3' has no 'INFINITY'
// CHECK-NOT: error [

// A generator CALL is iterable as it is: `for v in step(10, 14)` drives the
// Yield<i32> the call returns, with no `op in` in between, and so does a
// variable holding one, in place (Yield is move-only). Both used to be
// SC095E "'Yield<i32>' is not iterable".
// 10 + 11 + 12 + 13 = 46, then 1 + 2 + 3 = 6 from the variable: exit 52.

fn step(start: i32, stop: i32) -> yield i32 {
    var cur = start
    while cur < stop {
        yield cur
        cur += 1
    }
}

fn main() -> i32 {
    var total: i32 = 0
    for v in step(10, 14) {
        total += v
    }
    var g = step(1, 4)
    for v in g {
        total += v
    }
    return total
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -o %t.d/run --cache-dir %t.d/o
// RUN: %t.d/run; test $? -eq 52

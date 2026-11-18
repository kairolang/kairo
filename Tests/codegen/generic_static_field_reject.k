// A static field read through a generic instance finds only the statics the
// class declares: an unknown name is R025E, and the declared ones (read,
// assigned, compound-assigned) on two instances type-check clean.

class <T> Box {
    pub static count: i32 = 5
}

fn main() -> i32 {
    var r = Box<i32>::count
    Box<i64>::count += 1
    var q = Box<i32>::nope
    return r
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: generic_static_field_reject.k:12:23: error [R025E]: no member named 'nope' in {{.*}}

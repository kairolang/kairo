// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// A member miss on a named receiver stopped the pipeline before the
// expression typer, which binds the steps after a call, so later independent
// misses (`mk().dump()`) were never reported. Each is reported once.
// CHECK: second_member_miss_reported.k:[[#]]:[[#]]: error [R025E]: no member named 'dump' in 'T'
// CHECK: second_member_miss_reported.k:[[#]]:[[#]]: error [R025E]: no member named 'dump' in 'T'
// CHECK: second_member_miss_reported.k:[[#]]:[[#]]: error [R025E]: no member named 'dump2' in 'T'
class T {
    pub fn f(self) {}
}

fn mk() -> T {
    return T()
}

fn main() -> i32 {
    var t: T
    t.dump()
    mk().dump()
    mk().dump2()
    return 0
}

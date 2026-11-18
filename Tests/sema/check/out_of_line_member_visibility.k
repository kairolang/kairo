// A member declared in its class and defined out of line with no
// visibility keyword is as visible as the in-class declaration says
// (classes-out-of-line.mdx, Rules): a `pub` method, constructor, static
// function, operator and generic method are reached from another file, from
// a generic function too. A `priv`, `prot` or unmarked declaration stays
// what it is, and the note and the fix-it name the in-class declaration,
// where the keyword goes.

import inputs::out_of_line_visibility_lib::*

fn plain() -> i32 {
    var m = Meter(1)
    var n = Meter::make()
    var s = m + n
    return m.step() + m.peek() + s.v + m.scaled(2)
}

fn <T> generic_use(t: T) -> i32 {
    var m = Meter(1)
    return m.step() + Meter::make().peek()
}

fn refused() -> i32 {
    var m = Meter(1)
    return m.hidden() + m.unmarked() + m.guarded()
}

fn main() -> i32 {
    return plain() + generic_use(1) + lib_reads()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: {{.*}}out_of_line_member_visibility.k:25:13: error [SC242E]: method 'hidden' of 'Meter' is private
// CHECK-NEXT: fix-it:"{{.*}}out_of_line_visibility_lib.k":{12:5-12:9}:"pub"
// CHECK-NEXT: {{.*}}out_of_line_visibility_lib.k:12:13: note [SC242N]: 'hidden' is declared private here
// CHECK: {{.*}}out_of_line_member_visibility.k:25:26: error [SC242E]: method 'unmarked' of 'Meter' is private
// CHECK-NEXT: fix-it:"{{.*}}out_of_line_visibility_lib.k":{13:5-13:5}:"pub "
// CHECK-NEXT: {{.*}}out_of_line_visibility_lib.k:13:8: note [SC242N]: 'unmarked' is private by default
// CHECK: {{.*}}out_of_line_member_visibility.k:25:41: error [SC242E]: method 'guarded' of 'Meter' is protected
// CHECK-NEXT: fix-it:"{{.*}}out_of_line_visibility_lib.k":{14:5-14:9}:"pub"
// CHECK-NEXT: {{.*}}out_of_line_visibility_lib.k:14:13: note [SC242N]: 'guarded' is declared protected here

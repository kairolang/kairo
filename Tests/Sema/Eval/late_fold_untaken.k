// The checks after the late fold never see an untaken branch (EVAL.md
// 4.2b): TypeCycleCheck does not report the by-value cycle through one, and
// ShadowCheck does not warn on a same-type shadow inside one. The taken
// branch's shadow is warned on: the checks do run, on what stays.
struct Plain { var x: i32 }

class Node {
    eval if is_trivially_copyable!(Plain) {
        var next: *Node
        fn warned(c: bool) {
            var n: i32 = 0
            if c {
                var n: i32 = 1
            }
        }
    } else {
        var inner: Node
        fn quiet(c: bool) {
            var m: i32 = 0
            if c {
                var m: i32 = 1
            }
        }
    }
}

fn main() -> i32 {
    var k = Node()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: late_fold_untaken.k:13:{{[0-9]+}}: warning [R048W]: declaration of 'n' hides an outer binding of the same type
// CHECK-NEXT: late_fold_untaken.k:11:{{[0-9]+}}: note [R048N]: outer 'n' declared here{{.*}}

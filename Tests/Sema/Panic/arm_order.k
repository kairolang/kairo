// Any `catch` arm after a bare `catch` is an error (PANIC.md §3.1): the
// bare arm has already handled everything, so a later arm can only be a
// mistake. It was SC009W, a warning; the edit removes the arm. A second
// bare `catch` stays SC008E. The expression form rejects a later arm in the
// parser (S054E). These are structural (V), so they stop the run before
// typing.

struct E { var code: i32 }

fn thrower() panic(E) -> i32 { panic E { code: 1 } }

fn after_bare(x: i32) -> i32 {
    try {
        return thrower()
    } catch {
        return 0
    } catch e: E {
        return 1
    }
}

fn two_bare(x: i32) -> i32 {
    try {
        return thrower()
    } catch {
        return 0
    } catch {
        return 1
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: arm_order.k:17:7: error [SC001E]: no 'catch' arm may follow a bare 'catch': it already handles everything
// CHECK-NEXT: fix-it:"{{.*}}arm_order.k":{17:7-19:6}:""
// CHECK-NEXT: arm_order.k:15:7: note [SC001N]: the bare 'catch' is here
// CHECK: arm_order.k:27:7: error [SC008E]: duplicate bare `catch`; a previous bare `catch` already handles everything

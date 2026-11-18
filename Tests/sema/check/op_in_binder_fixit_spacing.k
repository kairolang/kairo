// SC298E offers `const ` on a lone binder whose loop header writes no
// `var` / `const` of its own. That is decided by what stands between `for`
// and the binder, not by the binder sitting one space after the keyword:
// two spaces, a tab or a line break leave the header bare.

class CPtr {
    var a: i32 = 1

    fn op in (const self) -> yield *const i32 {
        yield &self.a
    }
}

fn fixits(const c: CPtr) -> i32 {
    var s = 0
    // CHECK: op_in_binder_fixit_spacing.k:[[@LINE+2]]:9: error [SC298E]: 'for *x' does not bind
    // CHECK-NEXT: fix-it:"{{.*}}op_in_binder_fixit_spacing.k":{[[@LINE+1]]:9-[[@LINE+1]]:11}:"const *x"
    for *x in c { s += *x }
    // CHECK: op_in_binder_fixit_spacing.k:[[@LINE+2]]:10: error [SC298E]: 'for *y' does not bind
    // CHECK-NEXT: fix-it:"{{.*}}op_in_binder_fixit_spacing.k":{[[@LINE+1]]:10-[[@LINE+1]]:12}:"const *y"
    for  *y in c { s += *y }
    // CHECK: op_in_binder_fixit_spacing.k:[[@LINE+3]]:9: error [SC298E]: 'for *z' does not bind
    // CHECK-NEXT: fix-it:"{{.*}}op_in_binder_fixit_spacing.k":{[[@LINE+2]]:9-[[@LINE+2]]:11}:"const *z"
    for
        *z in c { s += *z }
    // CHECK: op_in_binder_fixit_spacing.k:[[@LINE+2]]:14: error [SC298E]: 'for *w' does not bind
    // CHECK-NOT: fix-it
    for var  *w in c { s += *w }
    return s
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error

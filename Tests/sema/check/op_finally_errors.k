// 0.2.0's destructor and allocation rules at the declaration and the call:
// `fn op delete(self)` is the old destructor spelling (S090E, fix-it to
// `finally`); a class's own `static fn op new` is not allowed (SC149E).
// (`x.finally()` on a class with no destructor: op_finally_no_dtor.k,
// XFAIL until the 0.3 design lands.)

class Old {
    var n: i32 = 0
    @move fn Old(self, other: Self) = default
    fn op delete(self) { self.n = 0 }
}

class Pool {
    static fn op new(size: usize, align: usize) -> unsafe *u8 { return &null }
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: op_finally_errors.k:10:11: error [S090E]: the destructor is spelled 'fn op finally(self)'; 'op delete' is no longer a destructor
// CHECK-NEXT: fix-it:"{{.*}}op_finally_errors.k":{10:11-10:17}:"finally"
// CHECK: op_finally_errors.k:14:18: error [SC149E]: a class cannot declare its own allocator ('op new'); objects are allocated with '@create' and freed with '@destroy' through the allocator in effect

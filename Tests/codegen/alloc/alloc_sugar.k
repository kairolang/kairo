// `@create` / `@destroy` are sugar for alloc.k's create / destroy, in
// both spellings: the generic call (`@create<T>(args)`, `@destroy<T>(p)`)
// and the docs' attribute form (`@create T(args)`, `@destroy p`,
// `@destroy(p)`). Each pair below must construct, read back and free, and
// the destructor must run exactly once per object.

import builtin::base::alloc::*

static dropped: i32 = 0

class P2 {
    pub var a: i64
    pub var b: i64
    fn P2(self, a: i64, b: i64) { self.a = a; self.b = b }
    fn op finally(self) { dropped = dropped + 1 }
    @move fn P2(self, other: Self) = default
}

fn main() -> i32 {
    var *p = @create<P2>(1i64, 2i64)
    var *q = @create P2(3i64, 4i64)
    var *n = @create i32(5)
    var sum = p->a + p->b + q->a + q->b + (*n) as i64
    @destroy(p)
    @destroy q
    @destroy<i32>(n)
    var *r = @create<P2>(10i64, 20i64)
    var t = r->b
    destroy(r)
    // 1 + 2 + 3 + 4 + 5 = 15, and three P2 destructors ran.
    if (sum != 15) || (t != 20) { return 1 }
    return dropped
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3

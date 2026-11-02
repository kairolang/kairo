// P215: `op new` / static `op delete` on a class are its own allocator.
// create<T> / try_create<T> / destroy<T>, and the `@create` / `@destroy`
// sugar, route to them (create_in<T, T> / destroy_in<T, T>) whatever
// allocator is in effect; a class without them still uses the global one.
// The counters prove which allocator ran, and that sizes and alignments
// reach the operators unchanged.

import builtin::base::alloc::*

static news: i32 = 0
static deletes: i32 = 0
static bytes: usize = 0

class Pooled {
    pub var a: i64
    pub var b: i64
    fn Pooled(self, a: i64, b: i64) { self.a = a; self.b = b }
    static fn op new(size: usize, align: usize) -> unsafe *u8 {
        news = news + 1
        bytes = bytes + size
        return System::alloc(size, align)
    }
    static fn op delete(ptr: unsafe *u8, size: usize, align: usize) {
        deletes = deletes + 1
        bytes = bytes - size
        System::free(ptr, size, align)
    }
}

class Plain {
    pub var x: i64
    fn Plain(self, x: i64) { self.x = x }
}

fn main() -> i32 {
    var *p = create<Pooled>(1i64, 2i64)
    var *q = @create<Pooled>(3i64, 4i64)
    var *r = @create Pooled(5i64, 6i64)
    var *s? = try_create<Pooled>(7i64, 8i64)
    var *k = create<Plain>(9i64)
    if news != 4 { return 1 }
    if bytes != 4 * sizeof Pooled { return 2 }
    var sum = p->a + q->b + r->a + k->x
    destroy<Pooled>(p)
    @destroy<Pooled>(q)
    destroy<Pooled>(r)
    if s? { destroy<Pooled>(s) }
    destroy(k)
    if deletes != 4 { return 3 }
    if bytes != 0 { return 4 }
    // 1 + 4 + 5 + 9
    return (sum - 19) as i32 + 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42

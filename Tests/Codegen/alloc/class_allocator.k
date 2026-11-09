// (deferred) / : `op new` / static `op delete` on a class would be
// its own allocator. Kairo rejects them (SC149E, 2026-11-08), so this program,
// which used to run its create / destroy through Pooled's pair, no longer
// compiles: each operator is an error at its name, and nothing else is.
// Allocation that counts goes through @set_global_allocator instead
// (Tests/alloc/class_allocator_counts.k).

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
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: class_allocator.k:18:18: error [SC149E]: a class cannot declare its own allocator ('op new')
// DIAG: class_allocator.k:23:18: error [SC149E]: a class cannot declare its own allocator ('op delete')

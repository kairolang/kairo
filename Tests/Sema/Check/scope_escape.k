// P226: a pointer from an open AllocatorScope that visibly outlives it is
// SC001W (Sema/Check/ScopeEscapeCheck.k). Positives: returned, stored to a
// static, stored to a local of an outer block, stored through a parameter.
// Negatives (no warning): the same pointer kept in a local of the scope's
// own block, freed inside it, returned when no scope is open, passed to a
// call, and allocated before the scope opens.

import builtin::base::alloc::*

static buf: [u8; 4096]
static cur: usize = 0
class Bump {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { var at = align_up(cur, align); cur = at + size; unsafe { return (&buf[0] as unsafe *u8) + at } }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return n <= o }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Bump>(ptr, o, n, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return Bump::alloc(size, align) }
    static fn enter() -> usize { return cur }
    static fn leave(m: usize) { cur = m }
    static fn range() -> (unsafe *u8, unsafe *u8) { unsafe { return (&buf[0] as unsafe *u8, (&buf[0] as unsafe *u8) + 4096) } }
}

class Node {
    pub var v: i64
    pub var next: *Node? = null
    fn Node(self, v: i64) { self.v = v }
}

static kept: *Node? = null

fn ret_direct() -> *Node {
    var s = AllocatorScope<Bump>()
    return create<Node>(1i64)
}

fn ret_local() -> *Node {
    var s = AllocatorScope<Bump>()
    var *n = create<Node>(2i64)
    return n
}

fn to_static() {
    var s = AllocatorScope<Bump>()
    var *n = create<Node>(3i64)
    kept = n
}

fn to_outer_local() -> i64 {
    var outer: *Node? = null
    {
        var s = AllocatorScope<Bump>()
        var *n = create<Node>(4i64)
        outer = n
    }
    return 0
}

fn through_param(head: *Node) {
    var s = AllocatorScope<Bump>()
    head->next = create<Node>(5i64)
}

fn take(n: *Node) -> i64 { return n->v }

fn fine() -> i64 {
    var *early = create<Node>(6i64)
    var total: i64 = 0
    {
        var s = AllocatorScope<Bump>()
        var *a = create<Node>(7i64)
        var inner: *Node? = null
        inner = a
        total = total + take(a)
        destroy(a)
    }
    destroy(early)
    return total
}

fn no_scope() -> *Node {
    return create<Node>(8i64)
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: scope_escape.k:33:12: warning [SC225W]: a pointer from the allocator scope is returned from the function; it dangles once the scope closes
// CHECK: scope_escape.k:39:12: warning [SC225W]: a pointer from the allocator scope is returned from the function; it dangles once the scope closes
// CHECK: scope_escape.k:45:12: warning [SC225W]: a pointer from the allocator scope is stored to the static variable 'kept'; it dangles once the scope closes
// CHECK: scope_escape.k:53:17: warning [SC225W]: a pointer from the allocator scope is stored to 'outer', which is declared outside the scope's block; it dangles once the scope closes
// CHECK: scope_escape.k:60:18: warning [SC225W]: a pointer from the allocator scope is stored through the parameter 'head', which outlives the scope; it dangles once the scope closes

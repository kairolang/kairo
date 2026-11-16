// Allocator scopes nest, and a pointer belongs to the scope that was
// innermost when it was allocated (Sema/Check/ScopeEscapeCheck.k). Opening
// an inner scope changes nothing for a pointer of the outer one: it may
// still go to a local of the outer scope's block, and when it does escape
// the note names the scope it came from. A pointer of the inner scope kept
// in a local of the outer block is an escape. A local of an outer block
// that was given a scoped pointer inside a nested block still holds it
// after that block.

import builtin::base::alloc::*

static buf: [u8; 4096]
static cur: usize = 0
class Bump {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { var at = align_up(cur, align); cur = at + size; unsafe { return (&buf[0] as unsafe *u8) + at } }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return n <= o }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Bump>(ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return Bump::alloc(size, align) }
    pub static fn enter() -> usize { return cur }
    pub static fn leave(m: usize) { cur = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { unsafe { return (&buf[0] as unsafe *u8, (&buf[0] as unsafe *u8) + 4096) } }
}

class Node {
    pub var v: i64
    pub var next: *Node? = null
    fn Node(self, v: i64) { self.v = v }
}


fn nested() -> i64 {
    var a = AllocatorScope<Bump>()
    var *p = create<Node>(1i64)
    var q: *Node? = null
    {
        var b = AllocatorScope<Bump>()
        q = p
        var *r = create<Node>(2i64)
        q = r
    }
    return 0
}

fn outer_from_inner() -> *Node {
    var a = AllocatorScope<Bump>()
    var *p = create<Node>(3i64)
    {
        var b = AllocatorScope<Bump>()
        return p
    }
}

fn kept_across_block(c: bool) -> *Node? {
    var a = AllocatorScope<Bump>()
    var q: *Node? = null
    if c {
        q = create<Node>(4i64)
    }
    return q
}

fn siblings() -> i64 {
    var keep: *Node? = null
    {
        var a = AllocatorScope<Bump>()
        var *p = create<Node>(5i64)
    }
    {
        var b = AllocatorScope<Bump>()
        var *p = create<Node>(6i64)
        var mine: *Node? = null
        mine = p
    }
    return 0
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: scope_escape_nested.k:40:13: warning [SC225W]: a pointer from the allocator scope is stored to 'q', which is declared outside the scope's block; it dangles once the scope closes
// CHECK-NEXT: scope_escape_nested.k:37:9: note [I900N]: the scope is opened here
// CHECK: scope_escape_nested.k:50:16: warning [SC225W]: a pointer from the allocator scope is returned from the function; it dangles once the scope closes
// CHECK-NEXT: scope_escape_nested.k:46:5: note [I900N]: the scope is opened here
// CHECK: scope_escape_nested.k:60:12: warning [SC225W]: a pointer from the allocator scope is returned from the function; it dangles once the scope closes
// CHECK-NEXT: scope_escape_nested.k:55:5: note [I900N]: the scope is opened here

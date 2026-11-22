// The guard `@set_scoped_allocator(A)` expands to is an AllocatorScope<A>
// local like a hand-written one, so a pointer from the scope that visibly
// outlives it is SC225W (sema/check/scope_escape.k has the rule).
// Positives: returned from a scoped function (directly and through a local),
// stored to a static from one, and stored from a scoped block to a local
// declared outside it. Negatives: kept in a local of the block and freed
// there, and returned from a function with no scope.

static buf: [u8; 4096]
static cur: usize = 0
class Bump {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { var at = (cur + align - 1) / align * align; cur = at + size; unsafe { return (&buf[0] as unsafe *u8) + at } }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return n <= o }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return Bump::alloc(n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return Bump::alloc(size, align) }
    pub static fn enter() -> usize { return cur }
    pub static fn leave(m: usize) { cur = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { unsafe { return (&buf[0] as unsafe *u8, (&buf[0] as unsafe *u8) + 4096) } }
}

class Node {
    pub var v: i64
    fn Node(self, v: i64) { self.v = v }
}

static kept: *Node? = null

@set_scoped_allocator(Bump)
fn ret_direct() -> *Node {
    return @create Node(1i64)
}

@set_scoped_allocator(Bump)
fn ret_local() -> *Node {
    var *n = @create Node(2i64)
    return n
}

@set_scoped_allocator(Bump)
fn to_static() {
    var *n = @create Node(3i64)
    kept = n
}

fn to_outer_local() -> i64 {
    var outer: *Node? = null
    @set_scoped_allocator(Bump) {
        var *n = @create Node(4i64)
        outer = n
    }
    return 0
}

fn fine() -> i64 {
    var total: i64 = 0
    @set_scoped_allocator(Bump) {
        var *a = @create Node(5i64)
        total = a->v
        @destroy a
    }
    return total
}

fn no_scope() -> *Node {
    return @create Node(6i64)
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: scoped_allocator_escape.k:31:12: warning [SC225W]: a pointer from the allocator scope is returned from the function; it dangles once the scope closes
// CHECK: scoped_allocator_escape.k:29:1: note [I900N]: the scope is opened here, and closing it at the end of this block frees everything allocated in it
// CHECK: scoped_allocator_escape.k:37:12: warning [SC225W]: a pointer from the allocator scope is returned from the function; it dangles once the scope closes
// CHECK: scoped_allocator_escape.k:34:1: note [I900N]: the scope is opened here, and closing it at the end of this block frees everything allocated in it
// CHECK: scoped_allocator_escape.k:43:12: warning [SC225W]: a pointer from the allocator scope is stored to the static variable 'kept'; it dangles once the scope closes
// CHECK: scoped_allocator_escape.k:40:1: note [I900N]: the scope is opened here, and closing it at the end of this block frees everything allocated in it
// CHECK: scoped_allocator_escape.k:50:17: warning [SC225W]: a pointer from the allocator scope is stored to 'outer', which is declared outside the scope's block; it dangles once the scope closes
// CHECK: scoped_allocator_escape.k:48:5: note [I900N]: the scope is opened here, and closing it at the end of this block frees everything allocated in it

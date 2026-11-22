import builtin::base::alloc::*
import std::io::println

// Two bump arenas with disjoint ranges, each counting what reaches it and
// how often its scope is opened and closed.
static arena:  [u8; 262144]
static cursor: [usize; 2]
static allocs: [i32; 2]
static frees:  [i32; 2]
static enters: [i32; 2]
static leaves: [i32; 2]

eval ARENA: usize = 131072

fn base(k: usize) -> unsafe *u8 { unsafe { return (&arena[0] as unsafe *u8) + k * ARENA } }
fn in_arena(k: usize, p: unsafe *const u8) -> bool {
    var a = p as usize
    var lo = base(k) as usize
    return a >= lo && a < lo + ARENA
}
fn in_any_arena(p: unsafe *const u8) -> bool { return in_arena(0, p) || in_arena(1, p) || in_levels(p) }

fn arena_alloc(k: usize, size: usize, align: usize) -> unsafe *u8 {
    var at = align_up(cursor[k], align)
    if at + size > ARENA { println(f"FAIL: arena {k} is full"); __builtin_abort() }
    cursor[k] = at + size
    allocs[k] += 1
    return base(k) + at
}
fn arena_free(k: usize, ptr: unsafe *u8) {
    if !in_arena(k, ptr) { println(f"FAIL: arena {k} freed a block it does not own"); __builtin_abort() }
    frees[k] += 1
}
fn arena_realloc(k: usize, ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
    var unsafe *q = arena_alloc(k, n, align)
    __builtin_copy(q, ptr, if o < n => o else => n)
    arena_free(k, ptr)
    return q
}

class ArenaA {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { return arena_alloc(0, size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { arena_free(0, ptr) }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return arena_realloc(0, ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return arena_alloc(0, size, align) }
    pub static fn enter() -> usize { enters[0] += 1; return cursor[0] }
    pub static fn leave(m: usize) { leaves[0] += 1; cursor[0] = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (base(0), base(0) + ARENA) }
}

class ArenaB {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { return arena_alloc(1, size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { arena_free(1, ptr) }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return arena_realloc(1, ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return arena_alloc(1, size, align) }
    pub static fn enter() -> usize { enters[1] += 1; return cursor[1] }
    pub static fn leave(m: usize) { leaves[1] += 1; cursor[1] = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (base(1), base(1) + ARENA) }
}

// One slice per open scope, so each activation of a recursive function has
// a range of its own and the test can tell which scope served a block.
static lv_arena:  [u8; 65536]
static lv_cursor: [usize; 16]
static lv_frees:  [i32; 16]
static lv_level:  usize = 0
static lv_enters: i32   = 0
static lv_leaves: i32   = 0
static lv_deepest: usize = 0

eval SLICE: usize = 4096

fn lv_base(k: usize) -> unsafe *u8 { unsafe { return (&lv_arena[0] as unsafe *u8) + k * SLICE } }
fn in_levels(p: unsafe *const u8) -> bool {
    var a = p as usize
    var lo = lv_base(0) as usize
    return a >= lo && a < lo + 16 * SLICE
}
fn level_of(p: unsafe *const u8) -> usize { return ((p as usize) - (lv_base(0) as usize)) / SLICE }

class Levels {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        var k = lv_level - 1
        var at = align_up(lv_cursor[k], align)
        lv_cursor[k] = at + size
        return lv_base(k) + at
    }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { lv_frees[level_of(ptr)] += 1 }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return n <= o }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Levels>(ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return Levels::alloc(size, align) }
    pub static fn enter() -> usize {
        lv_level += 1
        lv_enters += 1
        if lv_level > lv_deepest { lv_deepest = lv_level }
        lv_cursor[lv_level - 1] = 0
        return 0
    }
    pub static fn leave(m: usize) { lv_leaves += 1; lv_level -= 1 }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (lv_base(lv_level - 1), lv_base(lv_level - 1) + SLICE) }
}

class Node {
    pub var v: i64
    fn Node(self, v: i64) { self.v = v }
}

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
fn addr(n: *Node) -> unsafe *const u8 { return unsafe (n as unsafe *const u8) }
fn reset() {
    for var k = 0; k < 2; k += 1 { cursor[k] = 0; allocs[k] = 0; frees[k] = 0; enters[k] = 0; leaves[k] = 0 }
    lv_enters = 0
    lv_leaves = 0
    lv_deepest = 0
    for var k = 0; k < 16; k += 1 { lv_frees[k] = 0 }
}
fn long_string(n: i32) -> string {
    var s = ""
    for var i = 0; i < n; i += 1 { s.push('x') }
    return s
}

// A free function: `@create`, a string, a vector and a hash map built in it
// all come from the scope, and go back to it.
@set_scoped_allocator(ArenaA)
fn free_fn() -> i64 {
    check(enters[0] == 1 && leaves[0] == 0, "the scope is open in the body")
    var *n = @create Node(5i64)
    check(in_arena(0, addr(n)), "@create in a scoped function comes from the scope")
    var s = long_string(200)
    check(in_arena(0, unsafe (s.data() as unsafe *const u8)), "a string built in a scoped function comes from the scope")
    var v: [i32] = []
    for var i = 0; i < 100; i += 1 { v.push(i) }
    var *d? = v.data()
    if d? { unsafe { check(in_arena(0, d as unsafe *const u8), "a vector built in a scoped function comes from the scope") } }
    var m: {i32: i32} = {}
    for var i = 0; i < 100; i += 1 { m.insert(i, i) }
    var *me? = m.entries().data()
    if me? { unsafe { check(in_arena(0, me as unsafe *const u8), "a hash map built in a scoped function comes from the scope") } }
    var total = n->v + (s.size() as i64) + (v.size() as i64) + (m.size() as i64)
    @destroy n
    return total
}

class Shop {
    pub var made: i64 = 0

    // A method.
    @set_scoped_allocator(ArenaB)
    fn stock(self, k: i64) -> i64 {
        var *n = @create Node(k)
        check(in_arena(1, addr(n)), "@create in a scoped method comes from the scope")
        self.made += n->v
        @destroy n
        return self.made
    }

    // A static method.
    @set_scoped_allocator(ArenaA)
    static fn make(k: i64) -> i64 {
        var *n = @create Node(k)
        check(in_arena(0, addr(n)), "@create in a scoped static method comes from the scope")
        var r = n->v
        @destroy n
        return r
    }
}

// A constructor and a destructor: the scope covers the body.
class Tracked {
    pub var v: i64 = 0

    @set_scoped_allocator(ArenaA)
    fn Tracked(self, k: i64) {
        var *n = @create Node(k)
        check(in_arena(0, addr(n)), "@create in a scoped constructor comes from the scope")
        self.v = n->v
        @destroy n
    }

    @move fn Tracked(self, other: Self) = default

    @set_scoped_allocator(ArenaB)
    fn op finally(self) {
        var *n = @create Node(self.v)
        check(in_arena(1, addr(n)), "@create in a scoped destructor comes from the scope")
        @destroy n
    }
}

// A generic function: each instance opens the scope.
@set_scoped_allocator(ArenaB)
fn <T> boxed(x: T) -> T {
    var *p = @create T(x)
    check(in_arena(1, unsafe (p as unsafe *const u8)), "@create in a scoped generic function comes from the scope")
    var r = *p
    @destroy p
    return r
}

// An early return closes the scope as falling off the end does.
@set_scoped_allocator(ArenaA)
fn early(stop: bool) -> i32 {
    var *n = @create Node(1i64)
    if stop {
        @destroy n
        return 1
    }
    @destroy n
    return 2
}

// An expression body with a written return type.
@set_scoped_allocator(ArenaB)
fn expr_body() -> usize = long_string(100).size()

// Each activation opens its own scope, on its own slice; the block of every
// level is freed to its own level.
@set_scoped_allocator(Levels)
fn depth(n: usize) -> usize {
    var *p = @create Node(n as i64)
    check(level_of(addr(p)) == lv_level - 1, "each activation allocates from its own scope")
    var r: usize = 0
    if n > 0 { r = depth(n - 1) + 1 }
    @destroy p
    return r
}

fn main() -> i32 {
    reset()
    check(free_fn() == 5 + 200 + 100 + 100, "the scoped function's work")
    check(enters[0] == 1 && leaves[0] == 1, "one scope opened and closed for one call")
    check(allocs[0] >= 4 && frees[0] == allocs[0], "every block of the call went back to its scope")
    var *g = @create Node(9i64)
    check(!in_any_arena(addr(g)), "after the call, allocations are global again")
    @destroy g

    reset()
    var shop = Shop()
    check(shop.stock(3i64) == 3 && shop.stock(4i64) == 7, "the scoped method's work")
    check(enters[1] == 2 && leaves[1] == 2 && allocs[1] == 2 && frees[1] == 2, "one scope per method call")
    check(Shop::make(6i64) == 6, "the scoped static method's work")
    check(enters[0] == 1 && leaves[0] == 1 && allocs[0] == 1 && frees[0] == 1, "one scope for the static method call")

    reset()
    {
        var t = Tracked(8i64)
        check(t.v == 8 && enters[0] == 1 && leaves[0] == 1 && frees[0] == 1, "one scope for the constructor")
    }
    check(enters[1] == 1 && leaves[1] == 1 && frees[1] == 1, "one scope for the destructor")

    reset()
    check(boxed(41i64) == 41i64 && boxed(2.5) == 2.5, "the scoped generic function's work")
    check(enters[1] == 2 && leaves[1] == 2 && allocs[1] == 2 && frees[1] == 2, "one scope per instance call")

    reset()
    check(early(true) == 1 && early(false) == 2, "the early-return function's work")
    check(enters[0] == 2 && leaves[0] == 2 && frees[0] == 2, "an early return closes the scope once")

    reset()
    check(expr_body() == 100, "the expression-bodied function's work")
    check(enters[1] == 1 && leaves[1] == 1 && allocs[1] >= 1 && frees[1] == allocs[1], "an expression body runs in the scope")

    reset()
    check(depth(5) == 5, "the recursive function's work")
    check(lv_enters == 6 && lv_leaves == 6 && lv_deepest == 6 && lv_level == 0, "one scope per activation, all closed")
    for var k: usize = 0; k < 6; k += 1 { check(lv_frees[k] == 1, "each level's block went back to its own scope") }

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// `@set_scoped_allocator(A)` on a free function, a method, a static method,
// a constructor, a destructor, a generic function and an expression-bodied
// function opens an
// AllocatorScope<A> for the body: every allocation in it (`@create`, a
// string, a vector, a hash map) comes from A and goes back to it, the scope
// is entered and left once per call (an early return included), and a
// recursive function opens one scope per activation.
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

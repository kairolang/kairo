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

class Node {
    pub var v: i64
    fn Node(self, v: i64) { self.v = v }
}

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
fn reset() { for var k = 0; k < 2; k += 1 { cursor[k] = 0; allocs[k] = 0; frees[k] = 0; enters[k] = 0; leaves[k] = 0 } }

// Which allocator served each step of the generator: 0 A, 1 B, 2 neither.
static served: [i32; 8]
fn served_by(p: unsafe *const u8) -> i32 {
    if in_arena(0, p) { return 0 }
    if in_arena(1, p) { return 1 }
    return 2
}

// A generator with no attribute: each step allocates, records who served it,
// frees, and yields. It may be called and resumed inside a scope.
fn steps() -> yield i32 {
    for var i = 0; i < 4; i += 1 {
        var *n = @create Node(i as i64)
        served[i] = served_by(unsafe (n as unsafe *const u8))
        @destroy n
        yield i
    }
}

// Called and resumed inside a scoped block: its steps allocate from the
// scope in effect.
fn inside() {
    @set_scoped_allocator(ArenaA) {
        var g = steps()
        check(g.resume() && *g.current() == 0, "first step")
        check(g.resume() && *g.current() == 1, "second step")
    }
}

// Called outside any scope and resumed in and out of scopes: each step
// allocates from whichever scope is open when it is resumed, and from the
// global allocator after the block has closed.
fn across() {
    var g = steps()
    check(g.resume() && *g.current() == 0, "step 0, no scope")
    @set_scoped_allocator(ArenaA) {
        check(g.resume() && *g.current() == 1, "step 1, in A")
        @set_scoped_allocator(ArenaB) {
            check(g.resume() && *g.current() == 2, "step 2, in B")
        }
    }
    check(g.resume() && *g.current() == 3, "step 3, after the blocks closed")
    check(!g.resume(), "the generator is done")
}

// Called inside a scoped function.
@set_scoped_allocator(ArenaB)
fn in_scoped_fn() -> i32 {
    var total = 0
    for x in steps() { total += x }
    return total
}

fn main() -> i32 {
    reset()
    inside()
    check(served[0] == 0 && served[1] == 0, "a generator resumed inside the scope allocates from it")
    check(enters[0] == 1 && leaves[0] == 1 && frees[0] == allocs[0], "the block's scope opened and closed once")

    reset()
    across()
    check(served[0] == 2, "resumed with no scope open: the global allocator")
    check(served[1] == 0, "resumed in A: A")
    check(served[2] == 1, "resumed in B: B")
    check(served[3] == 2, "resumed after the blocks closed: the global allocator")
    check(enters[0] == 1 && leaves[0] == 1 && enters[1] == 1 && leaves[1] == 1, "each block's scope opened and closed once")

    reset()
    check(in_scoped_fn() == 6, "a generator driven by a for loop in a scoped function")
    check(served[0] == 1 && served[1] == 1 && served[2] == 1 && served[3] == 1, "every step allocates from the function's scope")
    check(enters[1] == 1 && leaves[1] == 1 && frees[1] == allocs[1], "the function's scope opened and closed once")

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// A generator carries no scope of its own: one called and resumed inside a
// `@set_scoped_allocator` block or function allocates, at each step, from
// whichever scope is open on the thread when that step runs, and from the
// global allocator once the block has closed. (A `yield` inside the scoped
// function or block itself is SC367E: sema/check/scoped_allocator_errors.k.)
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

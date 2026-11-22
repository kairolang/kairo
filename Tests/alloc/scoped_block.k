import builtin::base::alloc::*
import std::io::println

// Two bump arenas with disjoint ranges, each counting what reaches it, and
// a log of every scope opened (+1 A, +2 B) and closed (-1 A, -2 B).
static arena:  [u8; 262144]
static cursor: [usize; 2]
static allocs: [i32; 2]
static frees:  [i32; 2]
static events: [i32; 64]
static nevents: usize = 0

eval ARENA: usize = 131072

fn base(k: usize) -> unsafe *u8 { unsafe { return (&arena[0] as unsafe *u8) + k * ARENA } }
fn in_arena(k: usize, p: unsafe *const u8) -> bool {
    var a = p as usize
    var lo = base(k) as usize
    return a >= lo && a < lo + ARENA
}
fn in_any_arena(p: unsafe *const u8) -> bool { return in_arena(0, p) || in_arena(1, p) }
fn note(e: i32) { events[nevents] = e; nevents += 1 }

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
    pub static fn enter() -> usize { note(1); return cursor[0] }
    pub static fn leave(m: usize) { note(-1); cursor[0] = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (base(0), base(0) + ARENA) }
}

class ArenaB {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { return arena_alloc(1, size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { arena_free(1, ptr) }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return arena_realloc(1, ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return arena_alloc(1, size, align) }
    pub static fn enter() -> usize { note(2); return cursor[1] }
    pub static fn leave(m: usize) { note(-2); cursor[1] = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (base(1), base(1) + ARENA) }
}

class Node {
    pub var v: i64
    fn Node(self, v: i64) { self.v = v }
}

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
fn addr(n: *Node) -> unsafe *const u8 { return unsafe (n as unsafe *const u8) }
fn reset() {
    for var k = 0; k < 2; k += 1 { cursor[k] = 0; allocs[k] = 0; frees[k] = 0 }
    nevents = 0
}
fn log_is(const want: [i32]) -> bool {
    if nevents != want.size() { return false }
    for var i: usize = 0; i < nevents; i += 1 { if events[i] != want[i] { return false } }
    return true
}

// A block: the scope opens at `{` and closes at `}`.
fn one_block() -> i64 {
    var *before = @create Node(1i64)
    check(!in_any_arena(addr(before)), "before the block, allocations are global")
    var got: i64 = 0
    @set_scoped_allocator(ArenaA) {
        check(nevents == 1, "the scope is open at the start of the block")
        var *n = @create Node(2i64)
        check(in_arena(0, addr(n)), "@create in a scoped block comes from the scope")
        got = n->v
        @destroy n
    }
    check(nevents == 2, "the scope is closed after the block")
    var *after = @create Node(3i64)
    check(!in_any_arena(addr(after)), "after the block, allocations are global again")
    var r = before->v + got + after->v
    @destroy before
    @destroy after
    return r
}

// Nested blocks with different allocators: the inner one closes first, and a
// block of the outer scope freed inside the inner one goes back to the outer
// allocator.
fn nested() {
    @set_scoped_allocator(ArenaA) {
        var *outer = @create Node(1i64)
        check(in_arena(0, addr(outer)), "the outer block allocates from A")
        @set_scoped_allocator(ArenaB) {
            var *inner = @create Node(2i64)
            check(in_arena(1, addr(inner)), "the inner block allocates from B")
            @destroy outer
            check(frees[0] == 1 && frees[1] == 0, "an outer block freed inside the inner scope goes back to A")
            @destroy inner
        }
        var *again = @create Node(3i64)
        check(in_arena(0, addr(again)), "after the inner block, the outer scope is in effect again")
        @destroy again
    }
}

// Two attributes on one block: one scope each, the last written innermost.
fn two_on_one() {
    @set_scoped_allocator(ArenaA)
    @set_scoped_allocator(ArenaB) {
        var *n = @create Node(1i64)
        check(in_arena(1, addr(n)), "the innermost scope serves the block")
        @destroy n
    }
}

// The attribute on a function and on a block inside it.
@set_scoped_allocator(ArenaA)
fn fn_and_block() {
    var *a = @create Node(1i64)
    @set_scoped_allocator(ArenaB) {
        var *b = @create Node(2i64)
        check(in_arena(1, addr(b)), "the block's scope serves the block")
        @destroy b
    }
    check(in_arena(0, addr(a)), "the function's scope serves the function")
    @destroy a
}

// In a loop, one scope per iteration; `continue` and `break` out of the
// block close it.
fn in_loop() -> i32 {
    var runs = 0
    for var i = 0; i < 10; i += 1 {
        @set_scoped_allocator(ArenaA) {
            var *n = @create Node(i as i64)
            check(in_arena(0, addr(n)), "every iteration allocates from the scope")
            @destroy n
            runs += 1
            if i == 1 { continue }
            if i == 3 { break }
        }
    }
    return runs
}

// `return` out of the block closes it.
fn ret_out(stop: bool) -> i32 {
    @set_scoped_allocator(ArenaB) {
        var *n = @create Node(1i64)
        @destroy n
        if stop { return 7 }
    }
    return 8
}

fn main() -> i32 {
    reset()
    check(one_block() == 6, "the block's work")
    check(log_is([1, -1]), "one scope opened and closed for one block")
    check(allocs[0] == 1 && frees[0] == 1, "the block's allocation went back to its scope")

    reset()
    nested()
    check(log_is([1, 2, -2, -1]), "nested scopes close innermost first")
    check(allocs[0] == 2 && frees[0] == 2 && allocs[1] == 1 && frees[1] == 1, "each block went back to the scope that made it")

    reset()
    two_on_one()
    check(log_is([1, 2, -2, -1]), "two attributes on one block: the first written opens first and closes last")

    reset()
    fn_and_block()
    check(log_is([1, 2, -2, -1]), "the function's scope opens before the block's and closes after it")

    reset()
    check(in_loop() == 4, "the loop's work")
    check(log_is([1, -1, 1, -1, 1, -1, 1, -1]), "one scope per iteration, closed by continue and by break")

    reset()
    check(ret_out(true) == 7 && ret_out(false) == 8, "the returning block's work")
    check(log_is([2, -2, 2, -2]), "return out of the block closes it once")

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// `@set_scoped_allocator(A) { ... }` opens an AllocatorScope<A> at the `{`
// and closes it at the `}`: nested blocks close innermost first, a block of
// an outer scope freed inside an inner one goes back to the outer allocator,
// a block in a loop opens one scope per iteration, `break`, `continue` and
// `return` out of the block close it once, and two attributes on one node
// (or one on a function and one on a block in it) open one scope each, the
// first written outermost.
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

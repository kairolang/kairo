import builtin::base::alloc::*
import std::io::println

// Two bump arenas with disjoint ranges, each counting what reaches it.
static arena:  [u8; 262144]
static cursor: [usize; 2]
static allocs: [i32; 2]
static frees:  [i32; 2]
static moves:  [i32; 2]

eval ARENA: usize = 131072

fn base(k: usize) -> unsafe *u8 { unsafe { return (&arena[0] as unsafe *u8) + k * ARENA } }
fn in_arena(k: usize, p: unsafe *const u8) -> bool {
    var a = p as usize
    var lo = base(k) as usize
    return a >= lo && a < lo + ARENA
}
fn in_any_arena(p: unsafe *const u8) -> bool { return in_arena(0, p) || in_arena(1, p) }

fn arena_alloc(k: usize, size: usize, align: usize) -> unsafe *u8 {
    var at = align_up(cursor[k], align)
    if at + size > ARENA { println(f"FAIL: arena {k} is full"); __builtin_abort() }
    cursor[k] = at + size
    allocs[k] += 1
    // Dirty bytes, so a zeroed request has to clear them itself.
    __builtin_set_mem(base(k) + at, 0xAB as byte, size)
    return base(k) + at
}
fn arena_free(k: usize, ptr: unsafe *u8) {
    if !in_arena(k, ptr) { println(f"FAIL: arena {k} freed a block it does not own"); __builtin_abort() }
    frees[k] += 1
}
fn arena_realloc(k: usize, ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
    if !in_arena(k, ptr) { println(f"FAIL: arena {k} moved a block it does not own"); __builtin_abort() }
    moves[k] += 1
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
    pub static fn enter() -> usize { return cursor[0] }
    pub static fn leave(m: usize) { cursor[0] = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (base(0), base(0) + ARENA) }
}

class ArenaB {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { return arena_alloc(1, size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { arena_free(1, ptr) }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return arena_realloc(1, ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return arena_alloc(1, size, align) }
    pub static fn enter() -> usize { return cursor[1] }
    pub static fn leave(m: usize) { cursor[1] = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (base(1), base(1) + ARENA) }
}

// An element with a move constructor of its own is not trivially
// relocatable, so its vector grows by allocating a block and moving into it.
class Pinned {
    var v: i32
    fn Pinned(self, v: i32) { self.v = v }
    @move pub fn Pinned(self, other: Self) { self.v = other.v }
}

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
fn at(const v: [i32]) -> unsafe *const u8 { var d = v.data(); if d? { unsafe { return d as unsafe *const u8 } } return &null }
fn at_pinned(const v: [Pinned]) -> unsafe *const u8 { var d = v.data(); if d? { unsafe { return d as unsafe *const u8 } } return &null }
fn reset() { for var k = 0; k < 2; k += 1 { cursor[k] = 0; allocs[k] = 0; frees[k] = 0; moves[k] = 0 } }

// Built, grown and destroyed inside one scope: every block comes from the
// scope and goes back to it.
fn built_inside() {
    var s = AllocatorScope<ArenaA>()
    var v: [i32] = []
    for var i = 0; i < 1000; i += 1 { v.push(i) }
    check(in_arena(0, at(v)), "a vector built in a scope takes its storage from it")
    check(allocs[0] >= 1, "the scope saw the first block")
    check(moves[0] >= 1, "growth inside the scope goes through the scope's realloc")
    var sum = 0
    for var i: usize = 0; i < v.size(); i += 1 { sum += v[i] }
    check(sum == 499500, "the elements survive growth")
}

// A vector made with a block outside any scope and grown inside one keeps
// its allocator: the scope sees nothing, and the block stays outside it.
fn grow_inside(v: *[i32]) {
    var s = AllocatorScope<ArenaA>()
    for var i = 0; i < 1000; i += 1 { v->push(i) }
}

fn grow_pinned_inside(v: *[Pinned]) {
    var s = AllocatorScope<ArenaA>()
    for var i = 0; i < 100; i += 1 { v->push(Pinned(i)) }
}

// Made in scope A, grown inside a scope B nested in it: the block stays A's.
fn grow_in_b(v: *[i32]) {
    var s = AllocatorScope<ArenaB>()
    for var i = 0; i < 1000; i += 1 { v->push(i) }
    check(in_arena(0, at(*v)), "a block of the outer scope stays there when grown in an inner one")
}

fn nested() {
    var s = AllocatorScope<ArenaA>()
    var v: [i32] = []
    v.push(1)
    grow_in_b(&v)
    check(allocs[1] == 0 && moves[1] == 0, "the inner scope saw nothing")
}

// A vector with no block has no allocator yet: the first growth takes the
// allocator in effect, here the scope, so the block must be given back
// before the scope closes.
fn first_block_inside(v: *[i32]) {
    var s = AllocatorScope<ArenaA>()
    for var i = 0; i < 100; i += 1 { v->push(i) }
    check(in_arena(0, at(*v)), "an empty vector's first block comes from the scope in effect")
    v->clear()
    v->shrink_to_fit()
    check(frees[0] == allocs[0], "shrinking an empty vector frees to the scope that made the block")
}

// with_len of a zero-default type asks for zeroed memory; a scope has no
// zeroed entry point, so the block is cleared on the way out.
fn zeroed_inside() {
    var s = AllocatorScope<ArenaA>()
    var v = Vector<i32>::with_len(500)
    check(in_arena(0, at(v)), "with_len in a scope takes its storage from it")
    for var i: usize = 0; i < 500; i += 1 { check(v[i] == 0, "a zeroed block from a scope reads zero") }
}

fn main() -> i32 {
    reset()
    built_inside()
    check(frees[0] == allocs[0], "every block of a vector destroyed in its scope went back to it")

    reset()
    var g: [i32] = []
    g.push(7)
    grow_inside(&g)
    check(allocs[0] == 0 && moves[0] == 0, "the scope saw none of a vector it did not make")
    check(!in_any_arena(at(g)), "the block stays with the global allocator")
    check(g.size() == 1001 && g[0] == 7 && g[1000] == 999, "the elements survive growth")

    reset()
    var p: [Pinned] = []
    p.push(Pinned(-1))
    grow_pinned_inside(&p)
    check(allocs[0] == 0, "a moving growth replaces the block from its own allocator")
    check(!in_any_arena(at_pinned(p)), "the moved-to block is global")
    check(p.size() == 101 && p[0].v == -1 && p[100].v == 99, "the elements survive the move")

    reset()
    nested()
    check(frees[0] == allocs[0] && frees[1] == 0, "each block went back to the scope that made it")

    reset()
    var e: [i32] = []
    first_block_inside(&e)
    e.push(5)
    check(!in_any_arena(at(e)) && e[0] == 5, "after the scope closes it grows from the global allocator")

    reset()
    zeroed_inside()
    check(frees[0] == allocs[0], "the zeroed block went back to its scope")

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// A vector follows the allocator scope it is built in, as string does: its
// blocks come from the scope, grow through the scope's realloc and are freed
// to it. A vector whose block came from elsewhere keeps that allocator when
// it grows inside a scope (the realloc of a relocatable element and the
// allocate-and-move of one that is not), and a block from an outer scope
// stays there when grown inside an inner one. An empty vector has no
// allocator until its first block, which comes from the scope in effect.
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

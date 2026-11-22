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

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
fn at(const m: {i32: i32}) -> unsafe *const u8 { var d = m.entries().data(); if d? { unsafe { return d as unsafe *const u8 } } return &null }
fn reset() { for var k = 0; k < 2; k += 1 { cursor[k] = 0; allocs[k] = 0; frees[k] = 0; moves[k] = 0 } }
fn fill(m: *{i32: i32}, from: i32, to: i32) { for var i = from; i < to; i += 1 { m->insert(i, i * 2) } }
fn sum(const m: {i32: i32}) -> i64 {
    var s: i64 = 0
    for var i = 0; i < 2000; i += 1 { s += m.get_or(i, 0) as i64 }
    return s
}

// Built, grown (rehashed) and destroyed inside one scope.
fn built_inside() {
    var s = AllocatorScope<ArenaA>()
    var m: {i32: i32} = {}
    fill(&m, 0, 1000)
    check(in_arena(0, at(m)), "a map built in a scope takes its storage from it")
    check(allocs[0] >= 2, "every rehash inside the scope took a block from it")
    check(sum(m) == 999000, "the entries survive the rehashes")
    var c = m.copy()
    check(in_arena(0, at(c)), "a copy made in a scope takes its storage from it")
}

// A map with a block from outside any scope, grown inside one: the new
// blocks of its rehashes come from its own allocator.
fn grow_inside(m: *{i32: i32}) {
    var s = AllocatorScope<ArenaA>()
    fill(m, 1, 1000)
}

// Made in scope A, grown inside a scope B nested in it.
fn grow_in_b(m: *{i32: i32}) {
    var s = AllocatorScope<ArenaB>()
    fill(m, 1, 1000)
    check(in_arena(0, at(*m)), "a block of the outer scope stays there when rehashed in an inner one")
}

fn nested() {
    var s = AllocatorScope<ArenaA>()
    var m: {i32: i32} = {}
    m.insert(0, 0)
    grow_in_b(&m)
    check(allocs[1] == 0, "the inner scope saw nothing")
}

fn main() -> i32 {
    reset()
    built_inside()
    check(frees[0] == allocs[0], "every block of a map destroyed in its scope went back to it")

    reset()
    var g: {i32: i32} = {}
    g.insert(0, 0)
    grow_inside(&g)
    check(allocs[0] == 0, "the scope saw none of a map it did not make")
    check(!in_any_arena(at(g)), "the block stays with the global allocator")
    check(sum(g) == 999000, "the entries survive the rehashes")

    reset()
    nested()
    check(frees[0] == allocs[0] && frees[1] == 0, "each block went back to the scope that made it")

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// The hash table (under the hash map and set) follows the allocator scope it
// is built in: its blocks, and the scratch of a rebuild, come from the scope
// and are freed to it. A rehash of a table whose block came from elsewhere
// takes the new block from that block's allocator, so a map made outside a
// scope, or in an outer one, keeps its allocator when it grows inside.
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

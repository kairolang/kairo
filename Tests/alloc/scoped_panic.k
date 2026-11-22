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

class Boom {
    pub var code: i32
    fn Boom(self, code: i32) { self.code = code }
    fn op panic (const self) -> string { return "boom" }
}

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
fn reset() { for var k = 0; k < 2; k += 1 { cursor[k] = 0; allocs[k] = 0; frees[k] = 0; enters[k] = 0; leaves[k] = 0 } }
fn long_string(n: i32) -> string {
    var s = ""
    for var i = 0; i < n; i += 1 { s.push('x') }
    return s
}

// A string is alive in the scope when the panic leaves it: it is destroyed
// on the way out, back to the scope, and then the scope closes.
@set_scoped_allocator(ArenaA)
fn fails(k: i32) panic -> i32 {
    var s = long_string(100)
    check(in_arena(0, unsafe (s.data() as unsafe *const u8)), "the string comes from the scope")
    if k > 0 {
        panic Boom(k)
    }
    return s.size() as i32
}

fn inner_fails(k: i32) panic -> i32 {
    if k > 0 {
        panic Boom(k)
    }
    return 0
}

// The panic comes from a callee and passes through the scoped function.
@set_scoped_allocator(ArenaA)
fn passes_through(k: i32) panic -> i32 {
    var s = long_string(100)
    return inner_fails(k) + (s.size() as i32)
}

// A scoped block in a panicking function.
fn block_fails(k: i32) panic -> i32 {
    @set_scoped_allocator(ArenaB) {
        var s = long_string(100)
        if k > 0 {
            panic Boom(k)
        }
    }
    return 1
}

fn catch_fn(k: i32) -> i32 {
    try {
        return fails(k)
    } catch e: Boom {
        check(enters[0] == 1 && leaves[0] == 1, "the function's scope is closed before the catch runs")
        return e.code
    }
}

fn catch_through(k: i32) -> i32 {
    try {
        return passes_through(k)
    } catch e: Boom {
        check(enters[0] == 1 && leaves[0] == 1, "the scope is closed before the catch runs")
        return e.code
    }
}

fn catch_block(k: i32) -> i32 {
    try {
        return block_fails(k)
    } catch e: Boom {
        check(enters[1] == 1 && leaves[1] == 1, "the block's scope is closed before the catch runs")
        return e.code
    }
}

// A scoped block inside the `try` of the same function.
fn catch_local(k: i32) -> i32 {
    try {
        @set_scoped_allocator(ArenaB) {
            var s = long_string(100)
            var r = inner_fails(k)
        }
        return 0
    } catch e: Boom {
        check(enters[1] == 1 && leaves[1] == 1, "the block's scope is closed before the catch runs")
        return e.code
    }
}

fn main() -> i32 {
    reset()
    check(catch_fn(3) == 3, "the panic of a scoped function reaches the caller's catch")
    check(enters[0] == 1 && leaves[0] == 1, "the scope closed once on the panic path")
    check(allocs[0] >= 1 && frees[0] == allocs[0], "the string alive at the panic went back to the scope")

    reset()
    check(catch_fn(0) == 100, "no panic: the scoped function returns")
    check(enters[0] == 1 && leaves[0] == 1 && frees[0] == allocs[0], "the scope closed once on the return path")

    reset()
    check(catch_through(4) == 4, "a panic passing through a scoped function reaches the catch")
    check(enters[0] == 1 && leaves[0] == 1 && frees[0] == allocs[0], "the scope closed once as the panic passed")

    reset()
    check(catch_block(5) == 5, "the panic of a scoped block reaches the caller's catch")
    check(enters[1] == 1 && leaves[1] == 1 && frees[1] == allocs[1], "the block's scope closed once on the panic path")

    reset()
    check(catch_local(6) == 6, "the panic of a scoped block reaches the catch around it")
    check(enters[1] == 1 && leaves[1] == 1 && frees[1] == allocs[1], "the block's scope closed once before the local catch")

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// A panic raised inside a `@set_scoped_allocator` function or block, or
// passing through one from a callee, reaches the caller's `catch` with the
// scope closed exactly once: the locals alive at the panic are destroyed
// first, back to the scope, then the guard closes it, all before the catch
// body runs.
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

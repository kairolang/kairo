// A scoped function that calls itself opens the same allocator inside
// itself: every activation has the allocator's one range, each opens and
// closes a scope of its own, and a block is freed back to the allocator
// whichever activation frees it.

import builtin::base::alloc::*
import std::io::println

static arena:  [u8; 65536]
static cursor: usize = 0
static enters: i32   = 0
static leaves: i32   = 0
static frees:  i32   = 0

fn abase() -> unsafe *u8 {
    unsafe {
        return &arena[0] as unsafe *u8
    }
}

class Bump {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        var at = align_up(cursor, align)
        cursor = at + size
        return abase() + at
    }

    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        frees += 1
    }

    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool {
        return n <= o
    }

    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
        return realloc_by_copy<Bump>(ptr, o, n, align)
    }

    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        return Bump::alloc(size, align)
    }

    pub static fn enter() -> usize {
        enters += 1
        return cursor
    }

    pub static fn leave(m: usize) {
        leaves += 1
        cursor = m
    }

    pub static fn range() -> (unsafe *u8, unsafe *u8) {
        return (abase(), abase() + 65536)
    }
}

@set_scoped_allocator(Bump)
fn depth(n: i32, outer: unsafe *u8) -> i32 {
    var unsafe *p = @alloc(size: 16, align: 8)
    if n == 0 {
        // A block of an outer activation, freed in the innermost one.
        @free(size: 16, align: 8) outer
        @free(size: 16, align: 8) p
        return 0
    }

    var d = depth(n - 1, p) + 1
    return d
}

fn main() -> i32 {
    var unsafe *g = @alloc(size: 16, align: 8)
    var d = depth(5, g)
    @free(size: 16, align: 8) g
    println(f"{d} {enters} {leaves} {frees} {cursor}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// Six activations, six scopes; the two frees in the innermost one both
// reach Bump; the global block is freed outside every scope and does not;
// leaving the outermost scope gives the arena back whole.
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s
// CHECK: 5 6 6 2 0

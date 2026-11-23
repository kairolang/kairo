// The shapes a function can take between a plain `@create` and its
// `@destroy`, each run with no scope open and again inside an open
// scope. AllocSplit (Optimize/LLVM/AllocSplit.k) copies the global heap's
// path through them above -O0; the program must print what it prints at
// -O0, and the arena must see every allocation and free made while its
// scope is open: values defined on the copied path and used after it, a
// branch or a switch between the two, an early exit, nested and repeated
// pairs, a pair per loop iteration, a block freed in the next iteration,
// and a scope that opens or closes between the two.

import builtin::base::alloc::*
import std::io::println

class Point {
    pub var x: i64
    pub var y: i64
    pub fn Point(self, x: i64, y: i64) { self.x = x; self.y = y }
}

static arena:       [u8; 65536]
static cursor:      usize = 0
static bump_allocs: i32   = 0
static bump_frees:  i32   = 0

fn arena_base() -> unsafe *u8 { unsafe { return &arena[0] as unsafe *u8 } }

class Bump {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        var at = align_up(cursor, align)
        cursor = at + size
        bump_allocs += 1
        return arena_base() + at
    }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { bump_frees += 1 }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
        return realloc_by_copy<Bump>(ptr, o, n, align)
    }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        var unsafe *p = Bump::alloc(size, align)
        __builtin_set_mem(p, 0 as byte, size)
        return p
    }
    pub static fn enter() -> usize { return cursor }
    pub static fn leave(m: usize) { cursor = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (arena_base(), arena_base() + 65536) }
}

// A value computed from the block is used after the free.
fn carried(a: i64) -> i64 {
    var *p = @create Point(a, 1)
    var x = p->x * 3 + p->y
    @destroy p
    return x + a
}

// Two ways from the allocation to the free.
fn branched(a: i64) -> i64 {
    var *p = @create Point(a, 7)
    var r: i64 = 0
    if a > 5 {
        r = p->x
    } else {
        r = p->y + 2
    }
    @destroy p
    return r
}

// Three, through a switch.
fn switched(a: i64) -> i64 {
    var *p = @create Point(a, 9)
    var r: i64 = 0
    match a % 3 {
        case 0  { r = p->x }
        case 1  { r = p->y }
        default { r = p->x + p->y }
    }
    @destroy p
    return r
}

// The free is on two paths; one leaves early.
fn early(a: i64) -> i64 {
    var *p = @create Point(a, 4)
    if a < 0 {
        @destroy p
        return -1
    }
    var r = p->x + p->y
    @destroy p
    return r
}

// One pair inside another, then a third.
fn nested(a: i64) -> i64 {
    var *p = @create Point(a, 1)
    var *q = @create Point(a + 1, 2)
    var r = p->x + q->x
    @destroy q
    @destroy p
    var *s = @create Point(r, 3)
    r += s->y
    @destroy s
    return r
}

// A pair per iteration, with a way out between the two.
fn looped(n: i64) -> i64 {
    var sum: i64 = 0
    for var i: i64 = 0; i < n; i += 1 {
        var *p = @create Point(i, 2)
        if i == 7 {
            sum += 100
            @destroy p
            break
        }
        sum += p->x + p->y
        @destroy p
    }
    return sum
}

// Each iteration frees the block the one before it made.
fn handed_on(n: i64) -> i64 {
    var *prev = @create Point(0, 0)
    var sum: i64 = 0
    for var i: i64 = 1; i <= n; i += 1 {
        var *next = @create Point(i, prev->x)
        sum += next->x + next->y
        @destroy prev
        prev = next
    }
    @destroy prev
    return sum
}

// A scope opens and closes between the allocation and the free: the block
// is the outer allocator's on both sides of it.
fn scope_between(a: i64) -> i64 {
    var *p = @create Point(a, 5)
    var r: i64 = 0
    if a > 2 {
        @set_scoped_allocator(Bump) {
            var *q = @create Point(a, 6)
            r = q->x + q->y
            @destroy q
        }
    }
    r += p->x + p->y
    @destroy p
    return r
}

fn all(a: i64) -> i64 {
    var r = carried(a) + branched(a) + branched(a + 9)
    r += switched(a) + switched(a + 1) + switched(a + 2)
    r += early(a) + early(-a) + nested(a)
    r += looped(a) + looped(a + 9) + handed_on(a)
    r += scope_between(a) + scope_between(a + 3)
    return r
}

fn main() -> i32 {
    println(f"no scope {all(1)} {all(4)} allocs {bump_allocs} frees {bump_frees}")
    var r: i64 = 0
    @set_scoped_allocator(Bump) {
        r = all(1) + all(4)
    }
    println(f"in scope {r} allocs {bump_allocs} frees {bump_frees}")
    println(f"after {all(2)} allocs {bump_allocs} frees {bump_frees}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.o0 %t.o2 %t.o3 %t.exe
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.o2
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// RUN: rm -f %t.exe
// RUN: %kairo %s -O3 -o %t.exe --cache-dir %t.o3
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT:      no scope 220 296 allocs 3 frees 3
// OUT-NEXT: in scope 516 allocs 60 frees 60
// OUT-NEXT: after 237 allocs 61 frees 61

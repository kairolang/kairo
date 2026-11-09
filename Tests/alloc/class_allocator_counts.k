// is gone (a class cannot have its own allocator, SC149E), so this
// test now counts what replaced it: `@create` / `@destroy` -- the sugar, with
// no import -- take and return memory through the allocator in effect, here
// a counting global one (`@set_global_allocator`). Also the regression:
// Kairo's old `delete p` freed a `@create` block with C++'s global delete,
// a different allocator; `@destroy p` gives it back to the one it came from,
// so allocations and frees balance. The memory comes from C's malloc, so
// nothing here imports alloc.k. Counts are deltas: the runtime allocates too.

ffi "c" import "stdlib.h"

static news: i32 = 0
static deletes: i32 = 0
static live: usize = 0

fn c_free(p: unsafe *u8) { unsafe { free(p as unsafe *void) } }

class Counting {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        news = news + 1
        live = live + size
        unsafe { return malloc(size) as unsafe *u8 }
    }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        deletes = deletes + 1
        live = live - size
        c_free(ptr)
    }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return n <= o }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
        live = live - o + n
        unsafe { return realloc(ptr as unsafe *void, n) as unsafe *u8 }
    }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        news = news + 1
        live = live + size
        unsafe { return calloc(1, size) as unsafe *u8 }
    }
}

@set_global_allocator(Counting)

class Counted {
    pub var a: i64
    pub var b: i64
    fn Counted(self, a: i64, b: i64) { self.a = a; self.b = b }
}

fn main() -> i32 {
    var n0 = news
    var d0 = deletes
    var l0 = live
    var *x = @create<Counted>(1i64, 2i64)
    var *y = @create Counted(3i64, 4i64)
    if news - n0 != 2 { return 1 }
    if live - l0 != 2 * sizeof Counted { return 2 }
    if deletes != d0 { return 3 }
    var sum = x->a + x->b + y->a + y->b
    @destroy<Counted>(x)
    if deletes - d0 != 1 { return 4 }
    @destroy y
    if (deletes - d0 != 2) || (live != l0) { return 5 }
    // 1 + 2 + 3 + 4
    return (sum - 10) as i32 + 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42

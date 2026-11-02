// P215: a class's own `op new` / `op delete` is where create<T> /
// destroy<T> -- and the `@create` / `@destroy` sugar, with no import --
// take and return its memory, whatever allocator is in effect. The
// operators count their calls and bytes; main checks the counts at run
// time. The memory comes from C's malloc, so nothing here imports alloc.k.

ffi "c" import "stdlib.h"

static news: i32 = 0
static deletes: i32 = 0
static live: usize = 0

// C's free, named from outside the class: inside it `free` is the class's
// own (the parser declares `op delete` under that name).
fn c_free(p: unsafe *u8) { unsafe { free(p as unsafe *void) } }

class Counted {
    pub var a: i64
    pub var b: i64
    fn Counted(self, a: i64, b: i64) { self.a = a; self.b = b }
    static fn op new(size: usize, align: usize) -> unsafe *u8 {
        news = news + 1
        live = live + size
        unsafe { return malloc(size) as unsafe *u8 }
    }
    static fn op delete(ptr: unsafe *u8, size: usize, align: usize) {
        deletes = deletes + 1
        live = live - size
        c_free(ptr)
    }
}

fn main() -> i32 {
    var *x = @create<Counted>(1i64, 2i64)
    var *y = @create Counted(3i64, 4i64)
    if news != 2 { return 1 }
    if live != 2 * sizeof Counted { return 2 }
    if deletes != 0 { return 3 }
    var sum = x->a + x->b + y->a + y->b
    @destroy<Counted>(x)
    if deletes != 1 { return 4 }
    @destroy<Counted>(y)
    if (deletes != 2) || (live != 0) { return 5 }
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

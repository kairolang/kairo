// The type an allocation attribute names is a primitive, a name, a `::` path
// or a generic application, as the operand of `@alloc` and `@create` and as
// the allocator of `in:`. `@alloc(size: n, align: a)` takes no operand, so
// what follows it belongs to the enclosing expression.

import builtin::base::alloc::*
import std::io::println

static served: i32 = 0

class <T> Pool {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        served += 1
        return System::alloc(size, align)
    }

    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        served -= 1
        System::free(ptr, size, align)
    }
}

module shapes {
    pub struct Dot {
        pub var x: i32
    }
}

struct <A, B> Pair {
    pub var a: A
    pub var b: B
}

fn check(c: bool, what: string) {
    if !c {
        println(f"FAIL: {what}")
        __builtin_abort()
    }
}

fn main() -> i32 {
    var *d = @create(in: Pool<i32>) shapes::Dot { x: 4 }
    check(served == 1 && d->x == 4, "a path type from a generic allocator")
    @destroy(in: Pool<i32>) d
    check(served == 0, "back to the generic allocator")

    var one? = @alloc i32
    if one? {
        var *v = one.construct(7)
        check(*v == 7, "storage for a primitive")
        @free v
    }

    var many? = @alloc(count: 3) u8
    if many? {
        check(many.capacity() == 3, "storage for three primitives")
        @free many
    }

    var dot? = @alloc shapes::Dot
    if dot? {
        @free dot
    }

    var pair? = @alloc(in: Pool<u8>) Pair<i32, i64>
    check(served == 1, "a generic application from a generic allocator")
    if pair? {
        @free(in: Pool<u8>) pair
    }

    check(served == 0, "balanced")

    var n: usize = 8
    unsafe {
        var unsafe *h = @alloc(size: n * 2, align: 8) as unsafe *shapes::Dot
        check(h != &null, "the cast applies to the attribute's result")
        h->x = 9
        check(h->x == 9, "the block is writable through the cast")
        @free(size: n * 2, align: 8) (h as unsafe *u8)
    }

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

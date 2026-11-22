// `@alloc T`, `@alloc(count: n) T` and `@free` over a `*T`, an
// `Uninitialized<T>` and an `UninitializedSlice<T>`, with and without
// `in: A`. Freeing a `*T` or an `Uninitialized<T>` runs no destructor;
// freeing a slice destroys its live prefix. The allocator that served a block
// is the one that receives it back.

import builtin::base::alloc::*
import std::io::println

static a_served: i32 = 0
static a_freed:  i32 = 0
static g_served: i32 = 0
static g_freed:  i32 = 0
static a_bytes:  usize = 0
static a_free_bytes: usize = 0

class A {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { a_served += 1; a_bytes += size; return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { a_freed += 1; a_free_bytes += size; System::free(ptr, size, align) }
}

class G {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { g_served += 1; return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { g_freed += 1; System::free(ptr, size, align) }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<G>(ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { g_served += 1; return System::alloc_zeroed(size, align) }
}

@set_global_allocator(G)

static dtors: i32 = 0

class Box {
    pub var v: i32
    pub fn Box(self, v: i32) { self.v = v }
    @move fn Box(self, other: Self) = default
    fn op finally(self) { dtors += 1 }
}

type Int = i32

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }

fn main() -> i32 {
    // `@alloc T` gives an `Uninitialized<T>?`; `@free` on the constructed `*T`
    // returns the block without a destructor.
    var u? = @alloc Box
    check(u? && g_served == 1, "alloc T from the global allocator")
    if u? {
        var *o = u.construct(7)
        check(o->v == 7, "construct")
        @free o
    }
    check(g_freed == 1 && dtors == 0, "free of a *T runs no destructor")

    var ua? = @alloc(in: A) Box
    check(ua? && a_served == 1 && g_served == 1 && a_bytes == sizeof Box, "alloc in: A")
    if ua? {
        var *o = ua.construct(8)
        check(o->v == 8, "construct in A")
        @free(in: A) o
    }
    check(a_freed == 1 && a_free_bytes == sizeof Box && dtors == 0, "free(in: A) of a *T runs no destructor")

    // `@free` on an `Uninitialized<T>`.
    var u2? = @alloc Box
    if u2? { @free u2 }
    var u3? = @alloc(in: A) Box
    if u3? { @free(in: A) u3 }
    check(g_served == 2 && g_freed == 2 && a_served == 2 && a_freed == 2 && dtors == 0, "free of an Uninitialized<T>")

    // A slice: the live prefix is destroyed, the capacity is returned.
    var s? = @alloc(count: 4) Box
    check(s? && g_served == 3, "alloc count from the global allocator")
    if s? {
        s.push(1)
        s.push(2)
        check(s.size() == 2 && s.capacity() == 4, "slice size and capacity")
        @free s
    }
    check(g_freed == 3 && dtors == 2, "free of a slice destroys the live prefix")

    var s2? = @alloc(count: 8, in: A) Box
    check(s2? && a_served == 3, "alloc count in: A")
    if s2? {
        s2.push(1)
        s2.push(2)
        s2.push(3)
        @free(in: A) s2
    }
    check(a_freed == 3 && dtors == 5 && g_served == 3 && g_freed == 3, "free(in: A) of a slice")
    check(a_free_bytes == 2 * sizeof Box + 8 * sizeof Box, "the slice returns its whole capacity")

    // An empty slice destroys nothing.
    var s3? = @alloc(count: 2, in: A) Box
    if s3? { @free(in: A) s3 }
    check(dtors == 5 && a_served == 4 && a_freed == 4, "free of an empty slice")

    // A primitive element type is named through an alias.
    var n? = @alloc Int
    if n? { var *k = n.construct(5); check(*k == 5, "scalar"); @free k }
    check(g_served == 4 && g_freed == 4, "scalar balanced")

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe

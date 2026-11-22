// When the allocator fails, the fallible forms report it and change nothing:
// `@try_create` and `@alloc` give null without running a constructor, the
// byte forms give `&null`, `@try_resize` gives false and `@resize` gives
// `&null`, both leaving the block as it was. This holds for an `in: Failing`
// allocator and for a failing allocator in effect through an open scope.

import builtin::base::alloc::*
import std::io::println

static f_alloc: i32 = 0
static f_resize: i32 = 0
static g_alloc: i32 = 0
static g_free:  i32 = 0
static ctors: i32 = 0
static dtors: i32 = 0

// Every request fails.
class Failing {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { f_alloc += 1; return &null }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { f_resize += 1; return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { f_alloc += 1; return &null }
}

class G {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { g_alloc += 1; return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { g_free += 1; System::free(ptr, size, align) }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<G>(ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { g_alloc += 1; return System::alloc_zeroed(size, align) }
}

@set_global_allocator(G)

// A scoped allocator that serves `fs_budget` requests from a small arena and
// fails the rest; it never resizes.
static fs_arena: [u8; 4096]
static fs_budget: i32 = 0
static fs_cursor: usize = 0
static fs_free: i32 = 0

fn fs_base() -> unsafe *u8 { unsafe { return &fs_arena[0] as unsafe *u8 } }

class FailingScope {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        if fs_budget == 0 { return &null }
        fs_budget -= 1
        var at = align_up(fs_cursor, align)
        fs_cursor = at + size
        unsafe { return fs_base() + at }
    }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { fs_free += 1 }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return FailingScope::alloc(size, align) }
    pub static fn enter() -> usize { return fs_cursor }
    pub static fn leave(m: usize) { fs_cursor = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (fs_base(), fs_base() + 4096) }
}

class Box {
    pub var v: i32
    pub fn Box(self, v: i32) { self.v = v; ctors += 1 }
    @move fn Box(self, other: Self) = default
    fn op finally(self) { dtors += 1 }
}

struct Point {
    pub var x: i32
    pub var y: i32
}

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }

fn fill(p: unsafe *u8, n: usize) {
    for var i: usize = 0; i < n; i += 1 { unsafe { *(p + i) = (i + 1) as u8 } }
}

fn filled(p: unsafe *u8, n: usize) -> bool {
    for var i: usize = 0; i < n; i += 1 { unsafe { if *(p + i) != (i + 1) as u8 { return false } } }
    return true
}

fn failing_in() {
    var a? = @try_create(in: Failing) Box(1)
    check(!a?, "try_create(in: Failing) is null")
    check(ctors == 0 && dtors == 0, "no constructor runs when the allocation fails")
    var b? = @try_create(in: Failing) Point { x: 1, y: 2 }
    check(!b?, "try_create of an initializer is null")

    var u? = @alloc(in: Failing) Box
    check(!u?, "alloc T in: Failing is null")
    var s? = @alloc(count: 4, in: Failing) Box
    check(!s?, "alloc count in: Failing is null")

    var unsafe *p = @alloc(size: 64, align: 8, in: Failing)
    var unsafe *z = @alloc_zeroed(size: 64, align: 8, in: Failing)
    check(p == &null && z == &null, "byte allocation in: Failing is &null")
    check(f_alloc == 6, "Failing::alloc was reached once per request")

    // A zero size needs no memory, so it does not fail.
    var unsafe *e = @alloc(size: 0, align: 8, in: Failing)
    check(e != &null && f_alloc == 6, "zero size succeeds without asking Failing")

    // The block of another allocator: resize through `in: Failing` fails and leaves it alone.
    var unsafe *m = @alloc(size: 32, align: 8)
    fill(m, 32)
    var m0 = m as usize
    check(!(@try_resize(size: 32, new_size: 64, align: 8, in: Failing) m), "try_resize(in: Failing) is false")
    check(f_resize == 1 && m as usize == m0 && filled(m, 32), "the block is untouched after try_resize")
    var unsafe *n = @resize(size: 32, new_size: 64, align: 8, in: Failing) m
    check(n == &null && f_resize == 2, "resize(in: Failing) is &null")
    check(m as usize == m0 && filled(m, 32), "the block is untouched after resize")
    @free(size: 32, align: 8) m
    check(g_alloc == g_free, "the global block was freed once")
}

fn failing_scope() {
    fs_budget = 1
    fs_cursor = 0
    var scope = AllocatorScope<FailingScope>()

    // The one request the scope serves.
    var unsafe *m = @alloc(size: 32, align: 8)
    check(m != &null, "the scope serves its budget")
    fill(m, 32)
    var m0 = m as usize

    // Out of budget: every fallible form reports it.
    var a? = @try_create Box(2)
    check(!a? && ctors == 0, "try_create is null in a failing scope")
    var b? = @try_create Point { x: 1, y: 2 }
    check(!b?, "try_create of an initializer is null in a failing scope")
    var u? = @alloc Box
    check(!u?, "alloc T is null in a failing scope")
    var s? = @alloc(count: 3) Box
    check(!s?, "alloc count is null in a failing scope")
    var unsafe *p = @alloc(size: 16, align: 8)
    var unsafe *z = @alloc_zeroed(size: 16, align: 8)
    check(p == &null && z == &null, "byte allocation is &null in a failing scope")

    // The block is the scope's: neither resize moves it.
    check(!(@try_resize(size: 32, new_size: 64, align: 8) m), "try_resize is false in a failing scope")
    check(m as usize == m0 && filled(m, 32), "the block is untouched after try_resize")
    var unsafe *n = @resize(size: 32, new_size: 64, align: 8) m
    check(n == &null, "resize is &null in a failing scope")
    check(m as usize == m0 && filled(m, 32), "the block is untouched after resize")
    @free(size: 32, align: 8) m
    check(fs_free == 1, "the block returns to the scope")
}

fn main() -> i32 {
    failing_in()
    failing_scope()
    check(ctors == 0 && dtors == 0, "no object was ever constructed")
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe

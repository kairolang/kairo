// With an `AllocatorScope<Bump>` open, the allocation attributes without
// `in:` are served by the scope's allocator and freed back to it, an `in: B`
// goes to B regardless of the scope, and a block of the global allocator
// freed inside the scope reaches the global allocator. After the scope
// closes, the attributes without `in:` are served globally again.

import builtin::base::alloc::*
import std::io::println

static arena:  [u8; 65536]
static cursor: usize = 0

static bump_alloc:   i32 = 0
static bump_free:    i32 = 0
static bump_resize:  i32 = 0
static bump_realloc: i32 = 0
static b_alloc: i32 = 0
static b_free:  i32 = 0
static g_alloc: i32 = 0
static g_free:  i32 = 0

fn arena_base() -> unsafe *u8 { unsafe { return &arena[0] as unsafe *u8 } }

fn in_arena(p: unsafe *u8) -> bool {
    var lo = arena_base() as usize
    return (p as usize) >= lo && (p as usize) < lo + 65536
}

fn in_arena_obj(p: *Box) -> bool { unsafe { return in_arena(p as unsafe *u8) } }

class Bump {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        bump_alloc += 1
        var at = align_up(cursor, align)
        cursor = at + size
        unsafe { return arena_base() + at }
    }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { bump_free += 1 }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { bump_resize += 1; return n <= o }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { bump_realloc += 1; return realloc_by_copy<Bump>(ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        var unsafe *p = Bump::alloc(size, align)
        for var i: usize = 0; i < size; i += 1 { unsafe { *(p + i) = 0 } }
        return p
    }
    pub static fn enter() -> usize { return cursor }
    pub static fn leave(m: usize) { cursor = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (arena_base(), arena_base() + 65536) }
}

class B {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { b_alloc += 1; return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { b_free += 1; System::free(ptr, size, align) }
}

class G {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { g_alloc += 1; return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { g_free += 1; System::free(ptr, size, align) }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<G>(ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { g_alloc += 1; return System::alloc_zeroed(size, align) }
}

@set_global_allocator(G)

static dtors: i32 = 0

class Box {
    pub var v: i32
    pub fn Box(self, v: i32) { self.v = v }
    @move fn Box(self, other: Self) = default
    fn op finally(self) { dtors += 1 }
}

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }

fn inside(from_global: *Box, raw_global: unsafe *u8) {
    var scope = AllocatorScope<Bump>()

    // Typed objects.
    var *a = @create Box(1)
    check(in_arena_obj(a) && bump_alloc == 1, "create is served by the scope")
    var *b? = @try_create Box(2)
    check(b? && bump_alloc == 2, "try_create is served by the scope")
    if b? { check(in_arena_obj(b), "try_create block is in the arena") }
    var *c = @create(in: B) Box(3)
    check(!in_arena_obj(c) && b_alloc == 1 && bump_alloc == 2, "in: B bypasses the scope")
    @destroy a
    if b? { @destroy b }
    check(bump_free == 2 && dtors == 2, "destroy returns scope blocks to the scope")
    @destroy(in: B) c
    check(b_free == 1 && bump_free == 2, "destroy(in: B) goes to B")

    // A global block freed inside the scope reaches the global allocator.
    @destroy from_global
    check(g_free == 1 && bump_free == 2 && dtors == 4, "a global block freed in the scope reaches the global allocator")

    // Typed storage.
    var u? = @alloc Box
    check(u? && bump_alloc == 3, "alloc T is served by the scope")
    if u? { @free u }
    var s? = @alloc(count: 3) Box
    check(s? && bump_alloc == 4, "alloc count is served by the scope")
    if s? {
        s.push(1)
        s.push(2)
        @free s
    }
    check(bump_free == 4 && dtors == 6, "free of storage returns it to the scope")
    var ub? = @alloc(in: B) Box
    if ub? { @free(in: B) ub }
    check(b_alloc == 2 && b_free == 2 && bump_alloc == 4, "alloc and free in: B inside a scope")

    // Bytes.
    var unsafe *p = @alloc(size: 32, align: 8)
    var unsafe *z = @alloc_zeroed(size: 32, align: 8)
    check(in_arena(p) && in_arena(z) && bump_alloc == 6, "byte forms are served by the scope")
    for var i: usize = 0; i < 32; i += 1 { unsafe { *(p + i) = 7 } }
    p = @resize(size: 32, new_size: 128, align: 8) p
    check(in_arena(p) && bump_realloc == 1, "resize moves within the scope")
    unsafe { check(*p == 7 && *(p + 31) == 7, "resize keeps the contents") }
    check(!(@try_resize(size: 128, new_size: 256, align: 8) p), "try_resize routes to the scope's resize")
    check(bump_resize == 2, "try_resize reached Bump::resize")
    @free(size: 128, align: 8) p
    @free(size: 32, align: 8) z
    var unsafe *q = @alloc(size: 16, align: 8, in: B)
    check(!in_arena(q) && b_alloc == 3, "alloc bytes in: B bypasses the scope")
    @free(size: 16, align: 8, in: B) q

    // A raw global block freed in the scope.
    @free(size: 24, align: 8) raw_global
    check(g_free == 2, "a raw global block freed in the scope reaches the global allocator")

    // An explicit `in: Bump` is the scope's allocator, scope or not.
    var *e = @create(in: Bump) Box(9)
    check(in_arena_obj(e), "in: Bump")
    @destroy(in: Bump) e
}

fn main() -> i32 {
    var *g = @create(in: G) Box(4)
    var unsafe *raw = @alloc(size: 24, align: 8)
    check(g_alloc == 2 && !in_arena_obj(g), "global blocks before the scope")
    inside(g, raw)
    check(dtors == 7, "destructor count")

    // The scope is closed: no `in:` is the global allocator again.
    var before = bump_alloc
    var *h = @create Box(5)
    check(!in_arena_obj(h) && g_alloc == 3 && bump_alloc == before, "global again after the scope")
    @destroy h
    check(g_free == 3, "global free after the scope")
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe

// The byte forms: `@alloc(size:, align:)`, `@alloc_zeroed`, `@free(size:,
// align:)`, `@resize` and `@try_resize`, with and without `in: A`, with the
// keywords in several orders and over-aligned requests. A zero size returns a
// non-null dangling pointer without calling the allocator, and its free is a
// no-op.

import builtin::base::alloc::*
import std::io::println

static a_alloc:   i32 = 0
static a_zeroed:  i32 = 0
static a_free:    i32 = 0
static a_resize:  i32 = 0
static a_realloc: i32 = 0
static g_alloc:   i32 = 0
static g_zeroed:  i32 = 0
static g_free:    i32 = 0
static g_resize:  i32 = 0
static g_realloc: i32 = 0

// `resize` succeeds in place only for a shrink; growth moves through `realloc`.
class A {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { a_alloc += 1; return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { a_free += 1; System::free(ptr, size, align) }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { a_resize += 1; return n <= o }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { a_realloc += 1; return realloc_by_copy<A>(ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { a_zeroed += 1; return System::alloc_zeroed(size, align) }
}

class G {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { g_alloc += 1; return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { g_free += 1; System::free(ptr, size, align) }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { g_resize += 1; return n <= o }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { g_realloc += 1; return realloc_by_copy<G>(ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { g_zeroed += 1; return System::alloc_zeroed(size, align) }
}

@set_global_allocator(G)

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }

fn fill(p: unsafe *u8, n: usize) {
    for var i: usize = 0; i < n; i += 1 { unsafe { *(p + i) = (i + 1) as u8 } }
}

fn filled(p: unsafe *u8, n: usize) -> bool {
    for var i: usize = 0; i < n; i += 1 { unsafe { if *(p + i) != (i + 1) as u8 { return false } } }
    return true
}

fn zeroed(p: unsafe *u8, n: usize) -> bool {
    for var i: usize = 0; i < n; i += 1 { unsafe { if *(p + i) != 0 { return false } } }
    return true
}

fn aligned(p: unsafe *u8, a: usize) -> bool { return (p as usize) % a == 0 }

fn main() -> i32 {
    // `@alloc` and `@free`, global and `in: A`, keywords in both orders.
    var unsafe *p = @alloc(size: 64, align: 8)
    var unsafe *q = @alloc(align: 8, size: 64, in: A)
    var unsafe *r = @alloc(in: A, size: 32, align: 16)
    check(p != &null && q != &null && r != &null, "alloc returned a block")
    check(g_alloc == 1 && a_alloc == 2, "alloc routing")
    fill(p, 64)
    fill(q, 64)
    check(filled(p, 64) && filled(q, 64), "blocks are usable")
    @free(size: 64, align: 8) p
    @free(align: 8, size: 64, in: A) q
    @free(in: A, size: 32, align: 16) r
    check(g_free == 1 && a_free == 2, "free routing")

    // Over-aligned requests.
    var unsafe *o1 = @alloc(size: 256, align: 64)
    var unsafe *o2 = @alloc(size: 256, align: 64, in: A)
    var unsafe *o3 = @alloc_zeroed(size: 128, align: 64)
    var unsafe *o4 = @alloc_zeroed(size: 128, align: 64, in: A)
    check(aligned(o1, 64) && aligned(o2, 64) && aligned(o3, 64) && aligned(o4, 64), "align 64 honoured")
    check(zeroed(o3, 128) && zeroed(o4, 128), "over-aligned zeroed blocks are zero")
    @free(size: 256, align: 64) o1
    @free(size: 256, align: 64, in: A) o2
    @free(size: 128, align: 64) o3
    @free(size: 128, align: 64, in: A) o4

    // `@alloc_zeroed`: the zeroing entry point serves it, not `alloc`.
    var za = a_alloc
    var zg = g_alloc
    var unsafe *d = @alloc(size: 48, align: 8)
    fill(d, 48)
    @free(size: 48, align: 8) d
    var unsafe *z = @alloc_zeroed(size: 48, align: 8)
    var unsafe *y = @alloc_zeroed(align: 8, size: 48, in: A)
    check(g_zeroed == 2 && a_zeroed == 2, "alloc_zeroed reaches alloc_zeroed")
    check(g_alloc == zg + 1 && a_alloc == za, "alloc_zeroed does not go through alloc")
    check(zeroed(z, 48) && zeroed(y, 48), "alloc_zeroed bytes are zero")
    @free(size: 48, align: 8) z
    @free(size: 48, align: 8, in: A) y

    // A zero size: non-null, no allocator call, free is a no-op.
    var cg = g_alloc + g_zeroed + g_free
    var ca = a_alloc + a_zeroed + a_free
    var unsafe *e1 = @alloc(size: 0, align: 16)
    var unsafe *e2 = @alloc(size: 0, align: 16, in: A)
    var unsafe *e3 = @alloc_zeroed(size: 0, align: 32)
    var unsafe *e4 = @alloc_zeroed(size: 0, align: 32, in: A)
    check(e1 != &null && e2 != &null && e3 != &null && e4 != &null, "zero size gives a non-null pointer")
    check(aligned(e1, 16) && aligned(e3, 32), "the dangling pointer has the alignment")
    @free(size: 0, align: 16) e1
    @free(size: 0, align: 16, in: A) e2
    @free(size: 0, align: 32) e3
    @free(size: 0, align: 32, in: A) e4
    check(cg == g_alloc + g_zeroed + g_free && ca == a_alloc + a_zeroed + a_free, "zero size never reaches the allocator")

    // `@resize` grows by moving through `realloc` and preserves the contents.
    var unsafe *m = @alloc(size: 40, align: 8)
    fill(m, 40)
    m = @resize(size: 40, new_size: 400, align: 8) m
    check(m != &null && g_resize == 1 && g_realloc == 1, "resize grows through realloc")
    check(filled(m, 40), "resize preserves the old contents")
    m = @resize(new_size: 16, size: 400, align: 8) m
    check(g_resize == 2 && g_realloc == 1 && filled(m, 16), "resize shrinks in place")
    @free(size: 16, align: 8) m

    var unsafe *n = @alloc(size: 40, align: 64, in: A)
    fill(n, 40)
    n = @resize(size: 40, new_size: 1000, align: 64, in: A) n
    check(a_resize == 1 && a_realloc == 1 && g_resize == 2, "resize in: A")
    check(filled(n, 40) && aligned(n, 64), "the moved block keeps its contents and alignment")
    n = @resize(in: A, align: 64, new_size: 8, size: 1000) n
    check(a_resize == 2 && a_realloc == 1 && filled(n, 8), "resize in: A shrinks in place")
    @free(size: 8, align: 64, in: A) n

    // `@try_resize`: true only when the allocator resizes in place; the block
    // stays where it is.
    var unsafe *t = @alloc(size: 64, align: 8)
    fill(t, 64)
    var t0 = t as usize
    var grew = @try_resize(size: 64, new_size: 128, align: 8) t
    check(!grew && t as usize == t0 && filled(t, 64) && g_resize == 3 && g_realloc == 1, "try_resize refuses growth, block untouched")
    var shrank = @try_resize(new_size: 32, size: 64, align: 8) t
    check(shrank && filled(t, 32), "try_resize shrinks in place")
    @free(size: 32, align: 8) t

    var unsafe *u = @alloc(size: 64, align: 16, in: A)
    fill(u, 64)
    check(!(@try_resize(size: 64, new_size: 65, align: 16, in: A) u), "try_resize in: A refuses growth")
    check(@try_resize(size: 64, new_size: 10, align: 16, in: A) u, "try_resize in: A shrinks")
    check(a_resize == 4 && a_realloc == 1 && filled(u, 10), "try_resize in: A reached A::resize only")
    // A zero size on either side is not an in-place resize and does not call `resize`.
    check(!(@try_resize(size: 0, new_size: 8, align: 16, in: A) u), "try_resize from size 0")
    check(!(@try_resize(size: 8, new_size: 0, align: 16, in: A) u), "try_resize to size 0")
    check(a_resize == 4, "zero sizes never reach A::resize")
    @free(size: 64, align: 16, in: A) u

    check(g_alloc + g_zeroed == g_free && a_alloc + a_zeroed == a_free, "balanced")
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe

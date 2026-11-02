import builtin::base::alloc::*
import std::io::println
static arenas: [u8; 262144]
static cursor: [usize; 64]
static level: usize = 0
static frees: [i32; 64]
fn base(k: usize) -> unsafe *u8 { unsafe { return (&arenas[0] as unsafe *u8) + k * 4096 } }
fn level_of(p: unsafe *u8) -> usize { return ((p as usize) - (base(0) as usize)) / 4096 }
class Bump {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        var k = level - 1
        var at = align_up(cursor[k], align)
        cursor[k] = at + size
        return base(k) + at
    }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { frees[level_of(ptr)] += 1 }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return n <= o }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Bump>(ptr, o, n, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return Bump::alloc(size, align) }
    static fn enter() -> usize { return cursor[level - 1] }
    static fn leave(m: usize) { cursor[level - 1] = m }
    static fn range() -> (unsafe *u8, unsafe *u8) { return (base(level - 1), base(level - 1) + 4096) }
}
fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
static blocks: [usize; 64]
fn open_scope() -> AllocatorScope<Bump> { level += 1; return AllocatorScope<Bump>() }
fn nest(d: usize, max: usize, g: unsafe *u8) {
    if d == max {
        // innermost: free a block from every level, newest to oldest and back
        for var k: usize = 0; k < max; k += 1 {
            unsafe { free_raw(blocks[k] as unsafe *u8, 16, 8) }
        }
        free_raw(g, 32, 8)    // global block, deep inside
        return
    }
    var s = open_scope()      // moved out of open_scope
    var unsafe *p = alloc_raw(16, 8)
    check(level_of(p) == d, "alloc goes to the top scope")
    unsafe { blocks[d] = p as usize }
    nest(d + 1, max, g)
    level -= 1
}
fn main() -> i32 {
    for var max: usize = 1; max <= 40; max += 13 {
        for var k = 0; k < 64; k += 1 { frees[k] = 0; cursor[k] = 0 }
        var unsafe *g = alloc_bytes<System>(32, 8)
        nest(0, max, g)
        for var k: usize = 0; k < max; k += 1 { check(frees[k] == 1, "each level freed once, to its own scope") }
        // after closing everything, global again
        var unsafe *h = alloc_raw(16, 8)
        check(level_of(h) >= 64, "global after all scopes close")
        free_raw(h, 16, 8)
    }
    // reopen deep a second time: chunks are reused
    nest(0, 40, alloc_bytes<System>(32, 8))
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// The scope stack past its first chunk (16 frames): 1, 14, 27 and 40 scopes
// deep, each opened in a helper and moved out to its caller. At the
// innermost level a block from every level is freed and must reach its own
// scope's free (the packed-range scan below the top frame), and a global
// block freed there must reach Global without a scan (the top frame's
// bounding box). Then 40 deep again, on the chunks kept from the first run.
// The P226 warning for `blocks` is expected: the test keeps scope pointers
// on purpose.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe

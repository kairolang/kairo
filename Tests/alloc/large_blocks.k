import builtin::base::alloc::*
import std::io::println
ffi "c" import "stdlib.h"

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
fn byte_at(i: usize, seed: usize) -> u8 { return ((i * 7 + seed) & 255) as u8 }
fn fill(p: unsafe *u8, from: usize, to: usize, seed: usize) {
    for var i = from; i < to; i += 1 { unsafe { *(p + i) = byte_at(i, seed) } }
}
fn intact(p: unsafe *u8, n: usize, seed: usize) -> bool {
    for var i: usize = 0; i < n; i += 1 { unsafe { if *(p + i) != byte_at(i, seed) { return false } } }
    return true
}
fn zero(p: unsafe *u8, n: usize) -> bool {
    for var i: usize = 0; i < n; i += 1 { unsafe { if *(p + i) != 0 { return false } } }
    return true
}

eval MIB: usize = 1024 * 1024

// Grows a block by doubling from 16 bytes to 4 MiB with resize_raw, across
// the large-block threshold, then halves it back to 16; the bytes written
// at each size survive every step, and the alignment holds at every step.
fn chain(align: usize, seed: usize) {
    var n: usize = 16
    var unsafe *p = alloc_raw(n, align)
    check(p != &null, "chain alloc")
    fill(p, 0, n, seed)
    while n < 4 * MIB {
        p = resize_raw(p, n, n * 2, align)
        check(p != &null && (p as usize) % align == 0, f"grow to {n * 2} at align {align}")
        check(intact(p, n, seed), f"grow to {n * 2} keeps the bytes")
        fill(p, n, n * 2, seed)
        n *= 2
    }
    while n > 16 {
        p = resize_raw(p, n, n / 2, align)
        check(p != &null && (p as usize) % align == 0, f"shrink to {n / 2} at align {align}")
        n /= 2
        check(intact(p, n, seed), f"shrink to {n} keeps the bytes")
    }
    free_raw(p, n, align)
}

// The same through System's own entry points (resize_bytes<System>).
fn chain_system(align: usize, seed: usize) {
    var n: usize = 24
    var unsafe *p = alloc_bytes<System>(n, align)
    fill(p, 0, n, seed)
    while n < 3 * MIB {
        p = resize_bytes<System>(p, n, n * 3, align)
        check(p != &null && (p as usize) % align == 0, f"System grow to {n * 3}")
        check(intact(p, n, seed), "System grow keeps the bytes")
        fill(p, n, n * 3, seed)
        n *= 3
    }
    p = resize_bytes<System>(p, n, 1000, align)
    check(p != &null && intact(p, 1000, seed), "System shrink to 1000 keeps the bytes")
    free_bytes<System>(p, 1000, align)
}

fn main() -> i32 {
    // 1. growth and shrink across the threshold, at 8, 64, a page and past a page
    chain(8, 1)
    chain(64, 2)
    chain(4096, 3)
    chain(8192, 4)
    chain_system(8, 5)
    chain_system(32, 6)

    // 2. shrinking a large block: in place above the threshold; below it
    //    the allocator may refuse (the block would change path) and then
    //    the block keeps its size
    var unsafe *a = alloc_raw(MIB, 8)
    fill(a, 0, MIB, 7)
    check(Global::resize(a, MIB, 300000, 8), "shrink 1 MiB -> 300000 in place")
    check(intact(a, 300000, 7), "in-place shrink keeps the bytes")
    var an: usize = 300000
    if Global::resize(a, an, 60000, 8) {
        an = 60000
    }
    check(intact(a, an, 7), "a refused shrink leaves the block")
    a = Global::realloc(a, an, 50000, 8)
    check(a != &null && intact(a, 50000, 7), "realloc below the threshold keeps the bytes")
    free_raw(a, 50000, 8)

    // 3. failure leaves the block untouched, and it is still freed normally
    var unsafe *b = alloc_raw(MIB, 8)
    fill(b, 0, MIB, 8)
    check(resize_raw(b, MIB, usize::MAX - 65536, 8) == &null, "an impossible grow fails")
    check(!Global::resize(b, MIB, usize::MAX - 65536, 8), "an impossible in-place grow fails")
    check(resize_raw(b, MIB, usize::MAX - 100, 8) == &null, "a grow to usize::MAX - 100 fails")
    check(intact(b, MIB, 8), "a failed grow leaves the bytes")
    free_raw(b, MIB, 8)
    var unsafe *c = alloc_raw(5000, 64)
    fill(c, 0, 5000, 9)
    check(resize_raw(c, 5000, usize::MAX - 65536, 64) == &null, "an impossible over-aligned grow fails")
    check(intact(c, 5000, 9), "a failed over-aligned grow leaves the bytes")
    free_raw(c, 5000, 64)

    // 4. a block freed dirty is never handed out as zeroed
    for var round = 0; round < 3; round += 1 {
        var unsafe *d = alloc_raw(MIB, 8)
        fill(d, 0, MIB, 10)
        free_raw(d, MIB, 8)
        var unsafe *z = Global::alloc_zeroed(MIB, 8)
        check(z != &null && zero(z, MIB), "Global::alloc_zeroed after a dirty free")
        free_raw(z, MIB, 8)
        var unsafe *y = alloc_zeroed<System>(MIB, 8)
        check(y != &null && zero(y, MIB), "System alloc_zeroed after a dirty free")
        free_bytes<System>(y, MIB, 8)
    }

    // 5. System and Global take each other's large blocks
    var unsafe *e = alloc_bytes<System>(MIB, 8)
    fill(e, 0, MIB, 11)
    e = Global::realloc(e, MIB, 3 * MIB, 8)
    check(e != &null && intact(e, MIB, 11), "Global grows a System block")
    free_raw(e, 3 * MIB, 8)
    var unsafe *f = alloc_raw(2 * MIB, 16)
    fill(f, 0, 2 * MIB, 12)
    f = System::realloc(f, 2 * MIB, 200000, 16)
    check(f != &null && intact(f, 200000, 12), "System shrinks a Global block")
    System::free(f, 200000, 16)

    // 6. repeated allocate / free at sizes around the threshold and the
    //    cache's limit: a reused block is a whole one of the right size
    var sizes: [usize; 8] = [131071, 131072, 131073, 200000, MIB, 4 * MIB, 4 * MIB + 1, 5 * MIB]
    for var round: usize = 0; round < 40; round += 1 {
        var n = sizes[round % 8]
        var unsafe *g = alloc_raw(n, 8)
        check(g != &null, f"alloc {n}")
        fill(g, 0, n, round)
        check(intact(g, n, round), f"alloc {n} holds its bytes")
        free_raw(g, n, 8)
    }

    // 7. a freed 1 MiB block serves a 128 KiB request, which grows back to
    //    1 MiB and past it with its bytes
    for var round: usize = 0; round < 4; round += 1 {
        var unsafe *h = alloc_raw(MIB, 8)
        fill(h, 0, MIB, 20 + round)
        free_raw(h, MIB, 8)
        var hn: usize = 131072
        h = alloc_raw(hn, 8)
        fill(h, 0, hn, 30 + round)
        while hn < 2 * MIB {
            h = resize_raw(h, hn, hn * 2, 8)
            check(h != &null && intact(h, hn, 30 + round), f"regrow to {hn * 2} keeps the bytes")
            fill(h, hn, hn * 2, 30 + round)
            hn *= 2
        }
        free_raw(h, hn, 8)
    }

    // 8. a large block of the C heap freed by Kairo, where mimalloc is also
    //    the C heap (ELF and wasm, NetBSD's jemalloc aside)
    eval if !defined!(_WIN32) && !defined!(__APPLE__) && !defined!(__NetBSD__) {
        var k: unsafe *u8 = &null
        unsafe { k = malloc(MIB) as unsafe *u8 }
        fill(k, 0, MIB, 13)
        free_raw(k, MIB, 8)
    }

    // 9. a vector of 3M i32 grows through the large path and keeps every element
    var v: [i32] = [0]
    for var i: i32 = 1; i < 3000000; i += 1 { v.push(i) }
    var sum: i64 = 0
    for var i: usize = 0; i < 3000000; i += 1 { sum += v[i] }
    check(sum == 4499998500000, "vector of 3M elements")

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// The default allocator across its large-block threshold (rt/heap.h; on
// Linux a block of at least 128 KiB is a mapping grown with mremap and freed
// into a small cache): contents survive growth and shrink across it at
// 8, 64, 4096 and 8192 alignment, through Global and System; a large block
// shrinks in place above the threshold; a failed resize or realloc leaves
// the block untouched; a zeroed allocation never gets a dirty freed block;
// System and Global take each other's blocks; Kairo frees a large C-heap
// block; and a vector grows through the path. Every assertion holds on
// every target, with or without the large path.
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

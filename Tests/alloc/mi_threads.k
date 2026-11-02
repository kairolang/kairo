import builtin::base::alloc::*
import std::io::println
ffi "c" import "pthread.h"
ffi "c" import "stdlib.h"
ffi "c++" import "Inputs/atomic_flag.h"
fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
fn fill(p: unsafe *u8, n: usize, v: u8) { for var i: usize = 0; i < n; i += 1 { unsafe { *(p + i) = v } } }
fn all(p: unsafe *u8, n: usize, v: u8) -> bool { for var i: usize = 0; i < n; i += 1 { unsafe { if *(p + i) != v { return false } } } return true }

// --- cross-thread frees: producers allocate, consumers free --------------
static slots: [usize; 4096]
static ready: [i32; 4096]
fn producer(arg: unsafe *void) -> unsafe *void {
    var base: usize = 0
    unsafe { base = (arg as usize) * 1024 }
    for var i: usize = 0; i < 1024; i += 1 {
        var sz = (i % 40) * 24 + 8
        var unsafe *p = alloc_raw(sz, 8)
        fill(p, sz, 0x5Au8)
        unsafe { slots[base + i] = p as usize }
        unsafe { at_store1(&ready[base + i] as unsafe *i32) }
    }
    return &null
}
fn consumer(arg: unsafe *void) -> unsafe *void {
    var base: usize = 0
    unsafe { base = (arg as usize) * 1024 }
    for var i: usize = 0; i < 1024; i += 1 {
        var r = 0
        while r == 0 { unsafe { r = at_load(&ready[base + i] as unsafe *i32) } }
        var sz = (i % 40) * 24 + 8
        var p: unsafe *u8 = &null
        unsafe { p = slots[base + i] as unsafe *u8 }
        check(all(p, sz, 0x5Au8), "block intact across threads")
        free_raw(p, sz, 8)
    }
    return &null
}

fn main() -> i32 {
    // 1. small/large boundary: shrink and realloc across MI_SMALL_SIZE_MAX
    for var round = 0; round < 200; round += 1 {
        var unsafe *a = alloc_bytes<System>(4096, 8)
        fill(a, 4096, 0x11u8)
        a = resize_bytes<System>(a, 4096, 16, 8)          // large -> small: must move
        check(all(a, 16, 0x11u8), "shrink keeps content")
        free_bytes<System>(a, 16, 8)                       // small free on a small block
        var unsafe *b = alloc_bytes<System>(1500, 8)
        fill(b, 1500, 0x22u8)
        b = System::realloc(b, 1500, 1000, 8)              // realloc into the small range
        check(b != &null && all(b, 1000, 0x22u8), "realloc large->small keeps content")
        free_bytes<System>(b, 1000, 8)
        var unsafe *c = alloc_bytes<System>(64, 8)
        c = resize_bytes<System>(c, 64, 8000, 8)           // small -> large
        free_bytes<System>(c, 8000, 8)
        var unsafe *d = alloc_bytes<System>(100, 64)       // over-aligned, small
        check((d as usize) % 64 == 0, "aligned small")
        d = resize_bytes<System>(d, 100, 5000, 64)
        check((d as usize) % 64 == 0, "aligned realloc keeps alignment")
        free_bytes<System>(d, 5000, 64)
        var unsafe *z = alloc_zeroed<System>(3000, 128)
        check(all(z, 3000, 0u8) && (z as usize) % 128 == 0, "aligned zeroed")
        free_bytes<System>(z, 3000, 128)
    }
    // 2. one heap with C: a Kairo block released by C's free() (ELF and wasm)
    eval if !defined!(_WIN32) && !defined!(__APPLE__) {
        var unsafe *k = alloc_raw(48, 8)
        unsafe { free(k as unsafe *void) }
    }
    // 3. cross-thread frees
    var tp: [pthread_t; 4]
    var tc: [pthread_t; 4]
    unsafe {
        for var i = 0; i < 4; i += 1 {
            pthread_create(unsafe &tp[i], &null, producer, i as usize as unsafe *void)
            pthread_create(unsafe &tc[i], &null, consumer, i as usize as unsafe *void)
        }
        for var i = 0; i < 4; i += 1 { pthread_join(tp[i], &null); pthread_join(tc[i], &null) }
    }
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// System on mimalloc: blocks crossing the small/large boundary on shrink,
// realloc and over-aligned resize; a Kairo block released by C's free() on
// targets where mimalloc is also the C heap; and 4 producer threads whose
// blocks are freed by 4 consumer threads (mimalloc's cross-thread free).
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -I %S -o %t.exe --cache-dir %t.d
// RUN: %t.exe

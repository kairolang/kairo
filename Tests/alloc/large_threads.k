import builtin::base::alloc::*
import std::io::println
ffi "c" import "pthread.h"
ffi "c++" import "inputs/atomic_flag.h"

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
fn fill(p: unsafe *u8, n: usize, v: u8) { for var i: usize = 0; i < n; i += 4096 { unsafe { *(p + i) = v } } }
fn all(p: unsafe *u8, n: usize, v: u8) -> bool {
    for var i: usize = 0; i < n; i += 4096 { unsafe { if *(p + i) != v { return false } } }
    return true
}

eval MIB: usize = 1024 * 1024

// Each worker allocates, grows, checks and frees large blocks of a few
// sizes, so the threads race on the cache of freed blocks.
fn worker(arg: unsafe *void) -> unsafe *void {
    var id: usize = 0
    unsafe { id = arg as usize }
    var mark = (id + 1) as u8
    var sizes: [usize; 4] = [MIB, 2 * MIB, 131072, 300000]
    for var i: usize = 0; i < 2000; i += 1 {
        var n = sizes[(i + id) % 4]
        var unsafe *p = alloc_raw(n, 8)
        check(p != &null, "worker alloc")
        fill(p, n, mark)
        if i % 3 == 0 {
            p = resize_raw(p, n, n * 2, 8)
            check(p != &null && all(p, n, mark), "worker grow keeps the bytes")
            fill(p, n * 2, mark)
            n *= 2
        }
        check(all(p, n, mark), "no other thread wrote the block")
        free_raw(p, n, 8)
    }
    return &null
}

// Producers allocate 1 MiB blocks that consumers free: frees from other
// threads reach the same cache.
static slots: [usize; 1024]
static ready: [i32; 1024]
fn producer(arg: unsafe *void) -> unsafe *void {
    var base: usize = 0
    unsafe { base = (arg as usize) * 256 }
    for var i: usize = 0; i < 256; i += 1 {
        var unsafe *p = alloc_raw(MIB, 8)
        fill(p, MIB, 0x5Au8)
        unsafe { slots[base + i] = p as usize }
        unsafe { at_store1(&ready[base + i] as unsafe *i32) }
    }
    return &null
}
fn consumer(arg: unsafe *void) -> unsafe *void {
    var base: usize = 0
    unsafe { base = (arg as usize) * 256 }
    for var i: usize = 0; i < 256; i += 1 {
        var r = 0
        while r == 0 { unsafe { r = at_load(&ready[base + i] as unsafe *i32) } }
        var p: unsafe *u8 = &null
        unsafe { p = slots[base + i] as unsafe *u8 }
        check(all(p, MIB, 0x5Au8), "block intact across threads")
        free_raw(p, MIB, 8)
    }
    return &null
}

fn main() -> i32 {
    var tw: [pthread_t; 6]
    var tp: [pthread_t; 4]
    var tc: [pthread_t; 4]
    unsafe {
        for var i = 0; i < 6; i += 1 {
            pthread_create(unsafe &tw[i], &null, worker, i as usize as unsafe *void)
        }
        for var i = 0; i < 4; i += 1 {
            pthread_create(unsafe &tp[i], &null, producer, i as usize as unsafe *void)
            pthread_create(unsafe &tc[i], &null, consumer, i as usize as unsafe *void)
        }
        for var i = 0; i < 6; i += 1 { pthread_join(tw[i], &null) }
        for var i = 0; i < 4; i += 1 { pthread_join(tp[i], &null); pthread_join(tc[i], &null) }
    }
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// Large blocks (rt/heap.h) from several threads at once: workers allocate,
// grow and free blocks of four sizes, racing on the cache of freed blocks,
// while producer threads allocate 1 MiB blocks that consumer threads free.
// Every block holds only its own thread's bytes.
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -I %S -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

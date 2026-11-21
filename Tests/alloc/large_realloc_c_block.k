import builtin::base::alloc::*
import std::io::println
ffi "c" import "stdlib.h"
ffi "c" import "malloc.h"

eval MIB: usize = 1024 * 1024

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
fn fill(p: unsafe *u8, n: usize, v: u8) { for var i: usize = 0; i < n; i += 4096 { unsafe { *(p + i) = v } } }
fn kept(p: unsafe *u8, n: usize, v: u8) -> bool {
    for var i: usize = 0; i < n; i += 4096 { unsafe { if *(p + i) != v { return false } } }
    return true
}

fn main() -> i32 {
    // A large block the C heap made is mimalloc's: realloc to another large
    // size keeps it there, in place where mimalloc can.
    var p: unsafe *u8 = &null
    unsafe { p = malloc(MIB) as unsafe *u8 }
    check(p != &null, "C malloc")
    fill(p, MIB, 0x5au8)

    var q = Global::realloc(p, MIB, MIB - 4096, 8)
    check(q == p, "Global shrinks a C-heap block in place")
    var r = System::realloc(q, MIB - 4096, MIB - 8192, 8)
    check(r == p, "System shrinks a C-heap block in place")
    check(kept(r, MIB - 8192, 0x5au8), "the bytes stay")

    var usable: usize = 0
    unsafe { usable = malloc_usable_size(r as unsafe *void) }
    var g = Global::realloc(r, MIB - 8192, usable, 8)
    check(g == p, "Global grows a C-heap block within its usable size in place")
    check(kept(g, MIB - 8192, 0x5au8), "the bytes stay after the grow")

    // Past its usable size it may move; the bytes come along, and Kairo
    // frees what it ends up as.
    var m = Global::realloc(g, usable, 3 * MIB, 8)
    check(m != &null, "Global grows a C-heap block past its usable size")
    check(kept(m, MIB - 8192, 0x5au8), "the bytes move with it")
    free_raw(m, 3 * MIB, 8)

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// Global and System realloc a large block the C heap made without copying it
// when mimalloc can keep it in place: a shrink, and a grow within the
// block's usable size.
// REQUIRES: clang, host-linux
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

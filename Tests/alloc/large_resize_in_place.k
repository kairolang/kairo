import builtin::base::alloc::*
import std::io::println

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }
fn fill(p: unsafe *u8, n: usize, v: u8) { for var i: usize = 0; i < n; i += 1 { unsafe { *(p + i) = v } } }
fn all(p: unsafe *u8, n: usize, v: u8) -> bool {
    for var i: usize = 0; i < n; i += 1 { unsafe { if *(p + i) != v { return false } } }
    return true
}

fn main() -> i32 {
    // 1. mimalloc's block: a grow within its size class is in place. A
    //    17-byte block's class holds at least 24 bytes (classes are whole
    //    words) and at most 4000 (it is a small-page class).
    for var round = 0; round < 2; round += 1 {
        var unsafe *s = alloc_raw(17, 8)
        fill(s, 17, 0x31u8)
        check(Global::resize(s, 17, 24, 8), "Global grows 17 -> 24 in place")
        check(!Global::resize(s, 24, 4000, 8), "Global does not grow 24 -> 4000 in place")
        check(System::resize(s, 24, 20, 8), "System shrinks 24 -> 20 in place")
        check(System::resize(s, 20, 24, 8), "System grows 20 -> 24 in place")
        check(all(s, 17, 0x31u8), "in-place resize keeps the bytes")
        free_raw(s, 24, 8)
    }

    // 2. a large block: a grow within its mapped length is in place, a
    //    shrink above the threshold is in place, and one below it is
    //    refused, since the block would then be freed as mimalloc's
    var unsafe *p = alloc_raw(200000, 8)
    check((p as usize) % 4096 == 0, "a large block starts a page")
    fill(p, 200000, 0x42u8)
    check(Global::resize(p, 200000, 200704, 8), "grow within the mapped length")
    fill(p, 200704, 0x42u8)
    check(Global::resize(p, 200704, 150000, 8), "shrink above the threshold")
    check(!Global::resize(p, 150000, 100000, 8), "no in-place shrink below the threshold")
    check(!System::resize(p, 150000, 100000, 8), "System: no in-place shrink below the threshold")
    check(all(p, 150000, 0x42u8), "in-place resize keeps the bytes")
    var n: usize = 150000
    // Growing the mapping in place depends on the address space after it.
    if Global::resize(p, n, 600000, 8) {
        n = 600000
    }
    check(all(p, 150000, 0x42u8), "a large in-place grow keeps the bytes")
    free_raw(p, n, 8)

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// Resize in place (Global and System): mimalloc's block grows within its
// size class (mi_expand); on Linux a large block (rt/heap.h) grows within its
// mapped length and shrinks above the threshold, and is refused a shrink
// below it, which only a moving realloc may do.
// REQUIRES: clang, host-linux
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

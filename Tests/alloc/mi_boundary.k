import builtin::base::alloc::*
import std::io::println
fn main() -> i32 {
    for var round = 0; round < 2000; round += 1 {
        var unsafe *a = alloc_bytes<System>(100000, 8)
        a = resize_bytes<System>(a, 100000, 16, 8)
        free_bytes<System>(a, 16, 8)
        var unsafe *b = alloc_bytes<System>(300000, 8)
        b = System::realloc(b, 300000, 200, 8)
        free_bytes<System>(b, 200, 8)
    }
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// System frees a block of at most 128 words through mimalloc's small-page
// path, which takes the page from the pointer's 64 KiB alignment. A block
// from a larger page shrunk into that range would be freed through the wrong
// page header, so System::resize refuses that shrink and kairo_rt_realloc
// moves the block (rt/alloc.h). Without the guard this crashes within a few
// rounds.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe

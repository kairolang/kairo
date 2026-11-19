// StaticArena, called directly: every power-of-two alignment up to 4096 is
// honoured, freeing the most recent block rolls back and any other free is
// a no-op, a resize grows in place only the most recent block, realloc keeps
// the bytes, alloc_zeroed zeroes a rolled-back block, and exhaustion
// returns null with the arena still usable.

import std::io

fn addr(p: unsafe *u8) -> usize = p as usize

fn main() -> i32 {
    var bad = 0

    // Alignment, and that consecutive blocks do not overlap.
    var unsafe *first = StaticArena::alloc(1, 1)
    var prev_end = addr(first) + 1
    for var a: usize = 1; a <= 4096; a = a * 2 {
        var unsafe *p = StaticArena::alloc(3, a)
        if p == &null || addr(p) % a != 0 || addr(p) < prev_end {
            io::println(f"align {a}: bad block")
            bad += 1
        }

        prev_end = addr(p) + 3
    }

    // Free of the most recent block rolls back; of an older one, nothing.
    var unsafe *x = StaticArena::alloc(64, 8)
    var unsafe *y = StaticArena::alloc(64, 8)
    StaticArena::free(x, 64, 8)
    var unsafe *z = StaticArena::alloc(64, 8)
    if addr(z) == addr(x) {
        io::println("free of an older block was reused")
        bad += 1
    }

    StaticArena::free(z, 64, 8)
    var unsafe *z2 = StaticArena::alloc(64, 8)
    if addr(z2) != addr(z) {
        io::println("free of the last block did not roll back")
        bad += 1
    }

    // Resize: in place for the last block, refused for an older one.
    if !StaticArena::resize(z2, 64, 256, 8) {
        io::println("grow of the last block refused")
        bad += 1
    }

    if StaticArena::resize(y, 64, 128, 8) {
        io::println("grow of an older block accepted")
        bad += 1
    }

    if !StaticArena::resize(y, 64, 32, 8) {
        io::println("shrink refused")
        bad += 1
    }

    // Realloc of an older block moves it and keeps its bytes.
    unsafe {
        for var i: usize = 0; i < 32; i++ {
            y[i] = (i * 3) as u8
        }
    }

    var unsafe *y2 = StaticArena::realloc(y, 32, 100, 8)
    if y2 == &null || addr(y2) == addr(y) {
        io::println("realloc did not move")
        bad += 1
    } else {
        unsafe {
            for var i: usize = 0; i < 32; i++ {
                if y2[i] != (i * 3) as u8 {
                    bad += 1
                }
            }
        }
    }

    // A rolled-back block holds old bytes; alloc_zeroed clears them.
    var unsafe *w = StaticArena::alloc(16, 8)
    unsafe {
        for var i: usize = 0; i < 16; i++ {
            w[i] = 0xAB
        }
    }

    StaticArena::free(w, 16, 8)
    var unsafe *w2 = StaticArena::alloc_zeroed(16, 8)
    unsafe {
        for var i: usize = 0; i < 16; i++ {
            if w2[i] != 0 {
                io::println("alloc_zeroed left a byte")
                bad += 1
                break
            }
        }
    }

    // Exhaustion is null and leaves the arena usable.
    if StaticArena::alloc(1000000, 8) != &null {
        io::println("an oversized request succeeded")
        bad += 1
    }

    var n = 0
    while StaticArena::alloc(1024, 8) != &null {
        n += 1
    }

    if n == 0 || n > 64 {
        io::println(f"filled with {n} blocks")
        bad += 1
    }

    if StaticArena::alloc(1024, 8) != &null || StaticArena::realloc(w2, 16, 4096, 8) != &null {
        io::println("a full arena handed out a block")
        bad += 1
    }

    io::println(if bad == 0 => "ok" else => "FAILED")
    return bad
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK: ok

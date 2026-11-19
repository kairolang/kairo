// A whole program on the static heap: `@set_global_allocator(StaticArena)`
// with `-DKAIRO_STATIC_HEAP=65536` sends string and vector storage to a
// 64 KiB arena. The program runs; and growing a string past the arena
// fails the allocation, which shows the arena is the heap.
//
// The map is not exercised: its bodies are not written in this tree yet.

import std::io

@set_global_allocator(StaticArena)

fn main() -> i32 {
    var s = string()
    for var i = 0; i < 100; i++ {
        (i).append_to(&s)
    }

    var v: [i64] = [1, 2, 3]
    io::println(f"{s.size()} {v.size()}")
    eval if defined!(OVERFLOW_ARENA) {
        for var i = 0; i < 20000; i++ {
            (1000000 + i).append_to(&s)
        }

        io::println("not reached")
    }

    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -DKAIRO_STATIC_HEAP=65536 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: 190 3
// RUN: %nm -S %t.exe | %FileCheck %s --check-prefix=SYMS
// SYMS: 0000000000010000 {{[bB]}} {{.*}}static_arena9arena_memE
// RUN: %kairo %s -DKAIRO_STATIC_HEAP=65536 -DOVERFLOW_ARENA -o %t.full.exe --cache-dir %t.d2
// RUN: not %t.full.exe 2>&1 | %FileCheck %s --check-prefix=FULL
// FULL: out of memory
// FULL-NOT: not reached
// The define sets the size: 128 KiB here, not the 64 KiB default.
// RUN: %kairo %s -DKAIRO_STATIC_HEAP=131072 -o %t.big.exe --cache-dir %t.d3
// RUN: %t.big.exe | %FileCheck %s
// RUN: %nm -S %t.big.exe | %FileCheck %s --check-prefix=BIG
// BIG: 0000000000020000 {{[bB]}} {{.*}}static_arena9arena_memE

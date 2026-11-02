// With no `@set_global_allocator` in the program, the kairo_global_*
// symbols are the runtime's weak definitions (Lib/rt/global_alloc.c):
// System, malloc up to 2 * sizeof(void *) and the aligned entry points
// past it, exactly as alloc.k's System (P227).

ffi "c++" import "rt/global_alloc.h"

fn main() -> i32 {
    var unsafe *p = kairo_global_alloc(64, 64)
    if p == &null { return 1 }
    unsafe { if ((p as usize) & 63) != 0 { return 2 } }
    var unsafe *q = kairo_global_realloc(p, 64, 128, 64)
    if q == &null { return 3 }
    unsafe { if ((q as usize) & 63) != 0 { return 4 } }
    kairo_global_free(q, 128, 64)
    var unsafe *z = kairo_global_alloc_zeroed(32, 8)
    unsafe { if *z != 0u8 { return 5 } }
    if kairo_global_resize(z, 32, 64, 8) { return 6 }
    if !kairo_global_resize(z, 32, 16, 8) { return 7 }
    kairo_global_free(z, 32, 8)
    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-NOT: extern "C" unsigned char * kairo_global_alloc(
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42

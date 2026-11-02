// An `@align(64)` class is 64-aligned on the heap too: alloc.k's
// `create<T>` asks the allocator for `alignof T`, which is C++'s, and the
// record carries `__attribute__((aligned(64)))`.

import builtin::base::alloc::create

@align(64) class Al64 { var v: i64  fn Al64(self, v: i64) { self.v = v } }

fn main() -> i32 {
    if alignof Al64 != 64 { return 1 }
    var *p = create<Al64>(5)
    var a: usize = 0
    unsafe { a = p as unsafe *void as usize }
    if (a % 64) != 0 { return 2 }
    if p->v != 5 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe

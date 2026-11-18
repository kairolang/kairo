// Two files of one program set the global allocator. The importer
// and its import are one compile, so the driver sees both before any link
// and names both files.

import twice_lib

class ArenaA {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return &null }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return &null }
}

@set_global_allocator(ArenaA)

fn main() -> i32 { return twice_lib::two() }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK: error [SC138E]: two files set the global allocator: '{{twice_main|twice_lib}}.k' and '{{twice_main|twice_lib}}.k'; a program has one
// CHECK: note [SC138N]: '{{twice_main|twice_lib}}.k' sets it here

// `@set_global_allocator(A)` stands on a line of its own at file scope and
// is taken there, never stamped on the next declaration (P227). A file sets
// it once; anywhere the annotation buffer gets it, it is refused rather
// than dropped.

class Arena {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return &null }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return &null }
}

@set_global_allocator(Arena)
@set_global_allocator(Arena)

fn main() -> i32 {
    @set_global_allocator(Arena)
    var x = 1
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: set_global_allocator_placement.k:15:1: error [SC138E]: the global allocator is already set in this file; a program has one
// CHECK: set_global_allocator_placement.k:14:1: note [SC138N]: set here first
// CHECK: set_global_allocator_placement.k:18:5: error [SC139E]: '@set_global_allocator' stands on a line of its own at file scope; it is not an attribute of a declaration or statement

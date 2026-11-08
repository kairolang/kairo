// The type `@set_global_allocator` names must have the five static
// functions the kairo_global_* forwarders call (P227): a Kairo error at the
// attribute, not a clang error in generated code. A method of the same
// name is not one of them.

class Half {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    fn resize(self) -> bool { return false }
}

@set_global_allocator(Half)

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: global_allocator_conformance.k:12:1: error [SC141E]: 'Half' cannot be the global allocator: it has no static function 'resize'
// CHECK: global_allocator_conformance.k:6:1: note [SC141N]: the global allocator needs static alloc, free, resize, realloc and alloc_zeroed (FullAllocator)
// CHECK: global_allocator_conformance.k:12:1: error [SC141E]: 'Half' cannot be the global allocator: it has no static function 'realloc'
// CHECK: global_allocator_conformance.k:12:1: error [SC141E]: 'Half' cannot be the global allocator: it has no static function 'alloc_zeroed'
// CHECK-NOT: no static function 'alloc'

// Two files that set the global allocator, compiled apart and linked
// together (P227): both objects define the kairo_global_* symbols
// strongly, and the duplicate-symbol errors kld reports for them are one
// Kairo error naming both objects.

class ArenaC {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return &null }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return &null }
}

@set_global_allocator(ArenaC)

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d1 %t.d2 %t.d3
// RUN: %kairo -c %S/twice_lib.k -o %t.lib.o --cache-dir %t.d1
// RUN: %kairo -c %s -o %t.main.o --cache-dir %t.d2
// RUN: { %kairo %t.main.o %t.lib.o -o %t.exe --cache-dir %t.d3 2>&1 || true; } | %FileCheck %s
// CHECK: error [L001E]: the global allocator is set twice (@set_global_allocator): by {{.*}}main.o and by {{.*}}lib.o; a program has one, so exactly one linked file may set it
// CHECK-NOT: duplicate symbol

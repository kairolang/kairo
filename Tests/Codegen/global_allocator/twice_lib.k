// Imported by twice_main.k; sets a global allocator of its own.

class ArenaB {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return &null }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return &null }
}

@set_global_allocator(ArenaB)

pub fn two() -> i32 { return 2 }

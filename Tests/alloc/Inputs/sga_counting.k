// Counting allocator for the global-allocator tests: every alloc bumps n.
import builtin::base::alloc::*

pub static n: i32 = 0

pub class Counting {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { n += 1; return System::alloc(size, align) }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { System::free(ptr, size, align) }
    static fn resize(ptr: unsafe *u8, o: usize, nn: usize, align: usize) -> bool { return nn <= o }
    static fn realloc(ptr: unsafe *u8, o: usize, nn: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Counting>(ptr, o, nn, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return System::alloc_zeroed(size, align) }
}

pub fn count() -> i32 { return n }

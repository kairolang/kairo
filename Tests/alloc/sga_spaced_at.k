// `@ set_global_allocator(A)` with a space after the `@` is the same
// annotation to the parser, so the driver's pre-parse decision must see it
// too: the program builds whole with __KAIRO_GLOBAL_ALLOCATOR_SET, and
// create<T> reaches Counting (exit 1). Missing it refuses the graph build
// with SC140E, as if the file had been compiled apart.
import builtin::base::alloc::*
static n: i32 = 0
class Counting {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { n += 1; return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { System::free(ptr, size, align) }
    static fn resize(ptr: unsafe *u8, o: usize, nn: usize, align: usize) -> bool { return nn <= o }
    static fn realloc(ptr: unsafe *u8, o: usize, nn: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Counting>(ptr, o, nn, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return System::alloc_zeroed(size, align) }
}
@ set_global_allocator(Counting)
fn main() -> i32 {
    var *p = create<i64>(1i64)
    destroy<i64>(p)
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -o %t.d/a.exe
// RUN: %t.d/a.exe; test $? -eq 1

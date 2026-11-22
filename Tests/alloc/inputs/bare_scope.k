// Driven by ../scoped_no_import.k: the attribute's bound guard does not
// leak the name. The `@set_scoped_allocator` below puts alloc.k in this
// file's graph, and `AllocatorScope` written by hand must still need its
// import.
static buf: [u8; 64]
class Bump {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { unsafe { return &buf[0] as unsafe *u8 } }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return ptr }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return Bump::alloc(size, align) }
    pub static fn enter() -> usize { return 0 }
    pub static fn leave(m: usize) { }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { unsafe { return (&buf[0] as unsafe *u8, (&buf[0] as unsafe *u8) + 64) } }
}

@set_scoped_allocator(Bump)
fn scoped() { }

fn main() -> i32 {
    var s = AllocatorScope<Bump>()
    scoped()
    return 0
}

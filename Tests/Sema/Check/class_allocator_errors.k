// P215: a class's own allocator is checked at its declaration
// (Sema/Check/ClassAllocatorCheck.k): static, in a type, with Allocator's
// alloc / free signatures, both halves present. And a deduced destroy(p)
// of such a class, which cannot be routed, asks for its type instead of
// silently freeing to the global allocator.

import builtin::base::alloc::*

class NotStatic {
    fn op new(size: usize, align: usize) -> unsafe *u8 { return System::alloc(size, align) }
    static fn op delete(ptr: unsafe *u8, size: usize, align: usize) { System::free(ptr, size, align) }
}

class WrongSig {
    static fn op new(size: usize) -> unsafe *u8 { return System::alloc(size, 8) }
    static fn op delete(ptr: unsafe *u8, size: usize, align: usize) -> bool { System::free(ptr, size, align); return true }
}

class OnlyNew {
    static fn op new(size: usize, align: usize) -> unsafe *u8 { return System::alloc(size, align) }
}

class Good {
    pub var v: i64 = 0
    static fn op new(size: usize, align: usize) -> unsafe *u8 { return System::alloc(size, align) }
    static fn op delete(ptr: unsafe *u8, size: usize, align: usize) { System::free(ptr, size, align) }
    // The destructor is still `op delete(self)`; it is not the allocator.
    fn op delete(self) { }
    @move fn Good(self, other: Self) = default
}

fn deduced() {
    var *g = create<Good>()
    destroy(g)
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: class_allocator_errors.k:10:11: error [SC001E]: 'op new' is a class's own allocator and has no object to run on; declare it 'static fn op new(size: usize, align: usize) -> unsafe *u8'
// CHECK: class_allocator_errors.k:15:18: error [SC001E]: 'op new' is called as Allocator::alloc, so it must be 'static fn op new(size: usize, align: usize) -> unsafe *u8'
// CHECK: class_allocator_errors.k:16:18: error [SC001E]: 'op delete' is called as Allocator::free, so it must be 'static fn op delete(ptr: unsafe *u8, size: usize, align: usize)'
// CHECK: class_allocator_errors.k:20:18: error [SC001E]: a class with 'op new' must also declare 'static fn op delete(ptr: unsafe *u8, size: usize, align: usize)': its objects are freed by the allocator they came from
// CHECK: class_allocator_errors.k:34:5: error [SC001E]: 'Good' has its own allocator ('op new' / 'op delete'), so its destroy names it: write 'destroy<Good>(p)' or '@destroy<Good>(p)'

// A class cannot declare its own allocator (decided 2026-11-02,
// reaffirmed 2026-11-08). Every `op new` and every static `op delete` is
// SC149E at its name (Sema/Check/ClassAllocatorCheck.k), whatever its
// signature; the destructor `op finally(self)` is not one. Nothing routes
// create / destroy to a class any more, so a deduced destroy(p) is fine.

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
    // The destructor is `op finally(self)`; it is not an allocator.
    fn op finally(self) { }
    @move fn Good(self, other: Self) = default
}

fn deduced() {
    var *g = create<Good>()
    destroy(g)
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: class_allocator_errors.k:10:11: error [SC149E]: a class cannot declare its own allocator ('op new'); objects are allocated with '@create' and freed with '@destroy' through the allocator in effect
// CHECK: class_allocator_errors.k:11:18: error [SC149E]: a class cannot declare its own allocator ('op delete'); objects are allocated with '@create' and freed with '@destroy' through the allocator in effect
// CHECK: class_allocator_errors.k:15:18: error [SC149E]: a class cannot declare its own allocator ('op new'); objects are allocated with '@create' and freed with '@destroy' through the allocator in effect
// CHECK: class_allocator_errors.k:16:18: error [SC149E]: a class cannot declare its own allocator ('op delete'); objects are allocated with '@create' and freed with '@destroy' through the allocator in effect
// CHECK: class_allocator_errors.k:20:18: error [SC149E]: a class cannot declare its own allocator ('op new'); objects are allocated with '@create' and freed with '@destroy' through the allocator in effect
// CHECK: class_allocator_errors.k:25:18: error [SC149E]: a class cannot declare its own allocator ('op new'); objects are allocated with '@create' and freed with '@destroy' through the allocator in effect
// CHECK: class_allocator_errors.k:26:18: error [SC149E]: a class cannot declare its own allocator ('op delete'); objects are allocated with '@create' and freed with '@destroy' through the allocator in effect

// `@set_global_allocator(A)`: this file defines the five
// kairo_global_* symbols strongly, as forwarders to A's static functions,
// and they win over the runtime's weak System ones at link time. The
// program calls each symbol through the runtime header (the builtin's
// Global is what calls them in a real program) and counts which of
// Counting's functions answered.

ffi "c++" import "rt/global_alloc.h"

static calls: i32 = 0
static buf: [u8; 256]

class Counting {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { calls += 1; unsafe { return &buf[0] as unsafe *u8 } }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { calls += 10 }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { calls += 100; return false }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { calls += 1000; return &null }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { calls += 10000; return &null }
}

@set_global_allocator(Counting)

fn main() -> i32 {
    var unsafe *p = kairo_global_alloc(16, 8)
    kairo_global_free(p, 16, 8)
    kairo_global_resize(p, 16, 32, 8)
    kairo_global_realloc(p, 16, 32, 8)
    kairo_global_alloc_zeroed(16, 8)
    if calls != 11111 { return 1 }
    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: extern "C" unsigned char * kairo_global_alloc(decltype(sizeof(0)) size, decltype(sizeof(0)) align) noexcept {
// IR-NEXT: return{{.*}}::forwarders::Counting::alloc(size, align);
// IR: extern "C" void kairo_global_free(unsigned char * ptr, decltype(sizeof(0)) size, decltype(sizeof(0)) align) noexcept {
// IR: extern "C" bool kairo_global_resize(
// IR: extern "C" unsigned char * kairo_global_realloc(
// IR: extern "C" unsigned char * kairo_global_alloc_zeroed(
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42

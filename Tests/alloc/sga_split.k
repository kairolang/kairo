// Files compiled apart (--emit-scope=inputs, kcc -c) are not one graph:
// the driver still sees this file set the allocator, and defines
// __KAIRO_GLOBAL_ALLOCATOR_SET for it, but a file compiled in another run
// gets the define only from --global-allocator-set. An object built without
// it, linked with this one, is refused by kld before lld runs, naming the
// object to rebuild: its allocations would go to System, around Counting.
import builtin::base::alloc::*
static n: i32 = 0
class Counting {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { n += 1; return System::alloc(size, align) }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { System::free(ptr, size, align) }
    static fn resize(ptr: unsafe *u8, o: usize, nn: usize, align: usize) -> bool { return nn <= o }
    static fn realloc(ptr: unsafe *u8, o: usize, nn: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Counting>(ptr, o, nn, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return System::alloc_zeroed(size, align) }
}
@set_global_allocator(Counting)
fn main() -> i32 {
    var *p = create<i64>(1i64)
    destroy<i64>(p)
    return n
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, kcc
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --emit-scope=inputs -o %t.d/main.o
// RUN: %kairo %S/Inputs/sga_plain.k -c --emit-scope=inputs -o %t.d/plain.o
// RUN: { %kairo %t.d/main.o %t.d/plain.o --kairo-lib -o %t.d/mix.exe 2>&1 || true; } | %FileCheck %s --check-prefix=MIX
// MIX: {{.*}}main.o sets the global allocator, but {{.*}}plain.o was compiled without __KAIRO_GLOBAL_ALLOCATOR_SET, so its allocations go to System and bypass it; rebuild {{.*}}plain.o with --global-allocator-set
// RUN: test ! -e %t.d/mix.exe
// Rebuilt with the flag, the two link and Counting sees main's allocation.
// RUN: %kairo %S/Inputs/sga_plain.k -c --emit-scope=inputs --global-allocator-set -o %t.d/plain2.o
// RUN: %kairo %t.d/main.o %t.d/plain2.o --kairo-lib -o %t.d/ok.exe
// RUN: %t.d/ok.exe; test $? -eq 1
// kcc's -D of the macro means the same as the flag (it is not only a C++
// macro there), and so does -Xkairo --global-allocator-set.
// RUN: %kcc -c -D__KAIRO_GLOBAL_ALLOCATOR_SET %S/Inputs/sga_plain.k -o %t.d/plain3.o -Xkairo --cache-dir=%t.d/k3
// RUN: %kairo %t.d/main.o %t.d/plain3.o --kairo-lib -o %t.d/ok3.exe
// RUN: %t.d/ok3.exe; test $? -eq 1
// RUN: %kcc -c %S/Inputs/sga_plain.k -o %t.d/plain4.o -Xkairo --global-allocator-set -Xkairo --cache-dir=%t.d/k4
// RUN: %kairo %t.d/main.o %t.d/plain4.o --kairo-lib -o %t.d/ok4.exe
// RUN: %t.d/ok4.exe; test $? -eq 1

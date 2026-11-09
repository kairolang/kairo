// Driver half: a file that sets the global allocator makes the driver
// define __KAIRO_GLOBAL_ALLOCATOR_SET for every Kairo file it compiles, the
// builtin included, so Global is the class over the kairo_global_* symbols
// and create<T> reaches Counting. Without the define Global is System
// inlined, and create would bypass Counting (exit 0).
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
// REQUIRES: clang, llvm-objdump
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -o %t.d/a.exe --cache-dir %t.d/c1
// RUN: %t.d/a.exe; test $? -eq 1
// Every object, the builtin's too, was compiled with the define: none
// carries the "Global is System" flag (record kind 2, flags bit 1), and
// this file's says it sets the allocator (bit 2).
// RUN: find %t.d/c1 -name '*.o' | sort > %t.d/objs
// RUN: grep -q builtin %t.d/objs
// RUN: for o in $(cat %t.d/objs); do %objdump -s -j __kairo_abi $o; done > %t.d/notes
// RUN: %FileCheck %s --check-prefix=SET < %t.d/notes
// SET-NOT: 7f4b4142 490201
// SET: 7f4b4142 490202
// SET-NOT: 7f4b4142 490201
// The define written by hand means the same, and so does the flag.
// RUN: %kairo %s -D__KAIRO_GLOBAL_ALLOCATOR_SET -o %t.d/b.exe --cache-dir %t.d/c2
// RUN: %t.d/b.exe; test $? -eq 1
// RUN: %kairo %s --global-allocator-set -o %t.d/c.exe --cache-dir %t.d/c3
// RUN: %t.d/c.exe; test $? -eq 1
// No file sets one: every object, the builtin's too, says Global is System.
// RUN: %kairo %S/Inputs/sga_none.k -o %t.d/n.exe --cache-dir %t.d/c4
// RUN: %t.d/n.exe
// RUN: for o in $(find %t.d/c4 -name '*.o' | grep builtin); do %objdump -s -j __kairo_abi $o; done | %FileCheck %s --check-prefix=NONE
// NONE: 7f4b4142 490201

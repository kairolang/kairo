// Opening and closing an AllocatorScope compiles to straight-line code: the
// constructor is not an out-of-line call, and the object is as small as its
// three fields (a handle, the saved mark and the previous scope).

import builtin::base::alloc::*

static buf: [u8; 4096]
static cur: usize = 0
class Bump {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { var at = align_up(cur, align); cur = at + size; unsafe { return (&buf[0] as unsafe *u8) + at } }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return n <= o }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Bump>(ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return Bump::alloc(size, align) }
    pub static fn enter() -> usize { return cur }
    pub static fn leave(m: usize) { cur = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { unsafe { return (&buf[0] as unsafe *u8, (&buf[0] as unsafe *u8) + 4096) } }
}

@no_inline fn k_scope_open_close() { var s = AllocatorScope<Bump>() }

fn main() -> i32 {
    k_scope_open_close()
    return sizeof AllocatorScope<Bump> as i32 - 24
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, llvm-objdump, sysroot-x86_64-linux-musl
// RUN: rm -rf %t.d
// RUN: %kairo %s --target=x86_64-linux-musl -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %objdump -d --no-show-raw-insn %t.exe > %t.asm
// RUN: %FileCheck %s < %t.asm
// CHECK-LABEL: 18k_scope_open_closeEv>:
// CHECK: callq {{.*}}scope_push
// CHECK-NOT: ctor_pre
// CHECK-LABEL: <main>:

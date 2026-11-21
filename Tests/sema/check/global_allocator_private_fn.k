// The global allocator's five static functions are called by the runtime's
// forwarders, from outside the class, so one declared `priv` or `prot` is
// SC141E at '@set_global_allocator', with a note at the function and a
// fix-it making it public. Left unchecked it reaches the C++ step as an
// access error. A function with no visibility keyword is public.

import builtin::base::alloc::*

class Sec {
    priv static fn alloc(size: usize, align: usize) -> unsafe *u8 { return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { System::free(ptr, size, align) }
    prot static fn resize(ptr: unsafe *u8, o: usize, nn: usize, align: usize) -> bool { return false }
    static fn realloc(ptr: unsafe *u8, o: usize, nn: usize, align: usize) -> unsafe *u8 { return System::realloc(ptr, o, nn, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return System::alloc_zeroed(size, align) }
}

@set_global_allocator(Sec)

fn main() -> i32 {
    var *p = @create i32(1)
    var r = *p
    @destroy p
    return r - 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: global_allocator_private_fn.k:17:1: error [SC141E]: 'Sec' cannot be the global allocator: its static function 'alloc' is not public, and the runtime calls it from outside the class
// DIAG-NEXT: fix-it:"{{.*}}global_allocator_private_fn.k":{10:5-10:9}:"pub"
// DIAG-NEXT: global_allocator_private_fn.k:10:20: note [SC141N]: 'alloc' is declared here
// DIAG: global_allocator_private_fn.k:17:1: error [SC141E]: 'Sec' cannot be the global allocator: its static function 'resize' is not public
// DIAG-NEXT: fix-it:"{{.*}}global_allocator_private_fn.k":{12:5-12:9}:"pub"
// DIAG-NEXT: global_allocator_private_fn.k:12:20: note [SC141N]: 'resize' is declared here

// With the fix-its applied the program builds, and its allocation goes
// through Sec.
// REQUIRES: clang
// RUN: sed -e 's/priv static fn alloc/pub static fn alloc/' -e 's/prot static fn resize/pub static fn resize/' %s > %t.k
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %t.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe

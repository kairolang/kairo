// The global allocator set by one file reaches the allocations of every
// other: here the setter is an imported module (Inputs/sga_setter.k), this
// file and Inputs/sga_lib.k only allocate. The driver finds the setter in
// the import graph before compiling anything, so the define is on for
// this file, the library module and the builtin alike.
import builtin::base::alloc::*
import Inputs::sga_setter::*
import Inputs::sga_lib::*

fn main() -> i32 {
    var *p = create<i64>(1i64)
    destroy<i64>(p)
    lib_work()
    eval if defined!(__KAIRO_GLOBAL_ALLOCATOR_SET) { return setter_count() + 10 }
    return setter_count()
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// One here, one in sga_lib, and the define seen by this file: 12.
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12

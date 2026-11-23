// A block nothing uses does not reach the program's global allocator above
// -O0: the optimiser removes the allocation and its free, as it removes an
// unused `new` in C++, so an allocator that counts its calls counts fewer.
// The setter is an imported module (inputs/sga_setter.k); this file and
// inputs/sga_lib.k each create and destroy one unused i64 through the
// allocator in effect. At -O0 Counting sees both; at -O2 neither.
import builtin::base::alloc::*
import inputs::sga_setter::*
import inputs::sga_lib::*

fn main() -> i32 {
    var *p = create<i64>(1i64)
    destroy<i64>(p)
    lib_work()
    return setter_count()
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d0 %t.d2 %t.exe
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d0
// RUN: %t.exe; test $? -eq 2
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d2
// RUN: %t.exe; test $? -eq 0

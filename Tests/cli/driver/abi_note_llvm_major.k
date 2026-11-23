// kld reads each input's ABI note: two objects that use a calling
// convention (@preserve_most and friends) must come from one LLVM major,
// because LLVM does not keep those conventions stable across releases. An
// object that uses none never takes part, whatever LLVM built it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// a.o and z.o carry the toolchain's own LLVM major (the bundled clang's), b.o
// and n.o the next one.
// RUN: %clangxx -x c -c %S/inputs/abi_note.c '-DMAJOR=__clang_major__' -DBITS=1 -DFN=a_fn -o %t.d/a.o
// RUN: %clangxx -x c -c %S/inputs/abi_note.c '-DMAJOR=(__clang_major__+1)' -DBITS=1 -DFN=b_fn -o %t.d/b.o
// RUN: %clangxx -x c -c %S/inputs/abi_note.c '-DMAJOR=(__clang_major__+1)' -DBITS=0 -DFN=n_fn -o %t.d/n.o
// RUN: %clangxx -x c -c %S/inputs/abi_note.c '-DMAJOR=__clang_major__' -DBITS=0 -DFN=z_fn -o %t.d/z.o

// Both use one: rejected, naming two of them and their majors. The builtin
// library's own objects use one too and carry the toolchain's major, so the
// first named may be one of them rather than a.o.
// RUN: { %kairo %s %t.d/a.o %t.d/b.o -o %t.d/mix.exe --cache-dir %t.d/k1 2>&1 || true; } | %FileCheck %s --check-prefix=MIX
// MIX: '@preserve_most' is used by {{.*}}.o (LLVM {{[0-9]+}}) and {{.*}}b.o (LLVM {{[0-9]+}}); this calling convention is not stable across LLVM versions; rebuild both
// RUN: test ! -e %t.d/mix.exe

// Only one uses a convention: the other's major does not matter.
// RUN: %kairo %s %t.d/a.o %t.d/n.o -o %t.d/one.exe --cache-dir %t.d/k2
// RUN: %t.d/one.exe

// Neither does.
// RUN: %kairo %s %t.d/z.o %t.d/n.o -o %t.d/none.exe --cache-dir %t.d/k3
// RUN: %t.d/none.exe

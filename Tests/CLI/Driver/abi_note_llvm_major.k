// kld reads each input's ABI note: two objects that use a calling
// convention (@preserve_most and friends) must come from one LLVM major,
// because LLVM does not keep those conventions stable across releases. An
// object that uses none never takes part, whatever LLVM built it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %clangxx -x c -c %S/Inputs/abi_note.c -DMAJOR=22 -DBITS=1 -DFN=a_fn -o %t.d/a.o
// RUN: %clangxx -x c -c %S/Inputs/abi_note.c -DMAJOR=23 -DBITS=1 -DFN=b_fn -o %t.d/b.o
// RUN: %clangxx -x c -c %S/Inputs/abi_note.c -DMAJOR=23 -DBITS=0 -DFN=n_fn -o %t.d/n.o
// RUN: %clangxx -x c -c %S/Inputs/abi_note.c -DMAJOR=22 -DBITS=0 -DFN=z_fn -o %t.d/z.o

// Both use one: rejected, naming both and their majors.
// RUN: { %kairo %s %t.d/a.o %t.d/b.o -o %t.d/mix.exe --cache-dir %t.d/k1 2>&1 || true; } | %FileCheck %s --check-prefix=MIX
// MIX: '@preserve_most' is used by {{.*}}a.o (LLVM 22) and {{.*}}b.o (LLVM 23); this calling convention is not stable across LLVM versions; rebuild both
// RUN: test ! -e %t.d/mix.exe

// Only one uses a convention: the other's major does not matter.
// RUN: %kairo %s %t.d/a.o %t.d/n.o -o %t.d/one.exe --cache-dir %t.d/k2
// RUN: %t.d/one.exe

// Neither does.
// RUN: %kairo %s %t.d/z.o %t.d/n.o -o %t.d/none.exe --cache-dir %t.d/k3
// RUN: %t.d/none.exe

// `--emit` listing more than one kind with `-o` links: -o cannot name any
// one of several outputs, so it is the executable, and the listed kinds are
// written beside it as `<exe>.<ext>` (or under --cache-dir), each path
// printed. It is not I004F ("names one output, but this build emits
// 2"). One kind with -o is still that one output, and -c with several kinds
// and one -o is still the refusal.

fn main() -> i32 { return 3 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --emit obj,asm -o %t.d/app 2>&1 | %FileCheck %s --check-prefix=WROTE -DDIR=%t.d
// WROTE-DAG: kairo: wrote [[DIR]]/app.o
// WROTE-DAG: kairo: wrote [[DIR]]/app.s
// RUN: test -s %t.d/app.o
// RUN: %FileCheck %s --input-file=%t.d/app.s --check-prefix=ASM
// ASM: main
// RUN: %t.d/app; test $? -eq 3

// Without obj in the list the link still gets its objects; only the listed
// kinds are kept.
// RUN: %kairo %s --emit=asm,llvm-ir -o %t.d/ir/app
// RUN: test -s %t.d/ir/app.s
// RUN: test -s %t.d/ir/app.ll
// RUN: not test -e %t.d/ir/app.o
// RUN: %t.d/ir/app; test $? -eq 3

// Under --cache-dir the outputs stay there with the rest of the build's.
// RUN: %kairo %s --emit=obj,llvm-bc -o %t.d/c/app --cache-dir %t.d/c/k
// RUN: %t.d/c/app; test $? -eq 3
// RUN: ls %t.d/c/k | %FileCheck %s --check-prefix=CACHE
// CACHE-DAG: emit_with_link.o
// CACHE-DAG: emit_with_link.bc

// -c names one object: several kinds still have no single -o.
// RUN: { %kairo %s -c --emit obj,asm -o %t.d/one.o --cache-dir %t.d/k 2>&1 || true; } | %FileCheck %s --check-prefix=ONE
// ONE: fatal [I004F]: -o {{.*}}one.o names one output, but this build emits 2

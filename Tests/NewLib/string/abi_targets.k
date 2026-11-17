// string compiles for each ABI family: where the target is x86-64 or
// AArch64 the cold halves are preserve_most, whatever the object format and
// the C library; on any other target they are ordinary calls. The source is
// codegen_x86_64.k.

// --- lit wiring ---
// REQUIRES: newlib
// REQUIRES: sysroot-x86_64-linux-musl
// REQUIRES: sysroot-x86_64-windows-gnu
// REQUIRES: sysroot-x86_64-windows-msvc
// REQUIRES: sysroot-aarch64-linux-musl
// REQUIRES: sysroot-aarch64-windows-msvc
// REQUIRES: sysroot-arm64-macosx
// REQUIRES: sysroot-riscv64-linux-musl
// REQUIRES: sysroot-armv7-linux-musl
// REQUIRES: sysroot-wasm32-wasi
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new %S/codegen_x86_64.k -O2 --target=x86_64-linux-musl --emit=llvm-ir -o %t.d/a.ll --cache-dir %t.d/a
// RUN: %FileCheck %s --check-prefix=PM --input-file=%t.d/a.ll
// RUN: %kairo_new %S/codegen_x86_64.k -O2 --target=x86_64-windows-gnu --emit=llvm-ir -o %t.d/b.ll --cache-dir %t.d/b
// RUN: %FileCheck %s --check-prefix=PM --input-file=%t.d/b.ll
// RUN: %kairo_new %S/codegen_x86_64.k -O2 --target=x86_64-windows-msvc --emit=llvm-ir -o %t.d/c.ll --cache-dir %t.d/c
// RUN: %FileCheck %s --check-prefix=PM --input-file=%t.d/c.ll
// RUN: %kairo_new %S/codegen_x86_64.k -O2 --target=aarch64-linux-musl --emit=llvm-ir -o %t.d/d.ll --cache-dir %t.d/d
// RUN: %FileCheck %s --check-prefix=PM --input-file=%t.d/d.ll
// RUN: %kairo_new %S/codegen_x86_64.k -O2 --target=aarch64-windows-msvc --emit=llvm-ir -o %t.d/e.ll --cache-dir %t.d/e
// RUN: %FileCheck %s --check-prefix=PM --input-file=%t.d/e.ll
// RUN: %kairo_new %S/codegen_x86_64.k -O2 --target=arm64-apple-macosx --emit=llvm-ir -o %t.d/f.ll --cache-dir %t.d/f
// RUN: %FileCheck %s --check-prefix=PM --input-file=%t.d/f.ll
// RUN: %kairo_new %S/codegen_x86_64.k -O2 --target=riscv64-linux-musl --emit=llvm-ir -o %t.d/g.ll --cache-dir %t.d/g
// RUN: %FileCheck %s --check-prefix=PLAIN --input-file=%t.d/g.ll
// RUN: %kairo_new %S/codegen_x86_64.k -O2 --target=armv7-linux-musl --emit=llvm-ir -o %t.d/h.ll --cache-dir %t.d/h
// RUN: %FileCheck %s --check-prefix=PLAIN --input-file=%t.d/h.ll
// RUN: %kairo_new %S/codegen_x86_64.k -O2 --target=wasm32-wasi --emit=llvm-ir -o %t.d/i.ll --cache-dir %t.d/i
// RUN: %FileCheck %s --check-prefix=PLAIN --input-file=%t.d/i.ll

// PM:        call preserve_mostcc {{.*}}append_slow_
// PM:        call preserve_mostcc {{.*}}push_slow_
// PM:        call preserve_mostcc {{.*}}promote_

// PLAIN-NOT: preserve_mostcc
// PLAIN:     call {{.*}}append_slow_
// PLAIN-NOT: preserve_mostcc

// A user `thread` global in a shared library keeps the general-dynamic TLS
// model, so the library still works when it is dlopen'd (its TLS block has
// no static offset then); linked into an executable it is local-exec. The
// builtin's own `thread` globals are initial-exec in both.

thread counter: i64 = 0

ffi "c" fn tls_bump() -> i64 { counter += 1; return counter }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, sysroot-x86_64-linux-gnu
// RUN: { %kairo %s --target=x86_64-linux-gnu --shared --print-ir -o %t.so 2>&1 || true; } | %FileCheck %s --check-prefix=SHARED
// SHARED: constinit thread_local signed long counter = 0;
// SHARED-NOT: counter __attribute
// RUN: { %kairo %s --target=x86_64-linux-gnu --print-ir -o %t.exe 2>&1 || true; } | %FileCheck %s --check-prefix=EXE
// EXE: constinit thread_local signed long counter __attribute((tls_model("local-exec"))) = 0;
// RUN: rm -rf %t.d
// RUN: %kairo %s --target=x86_64-linux-gnu --shared -O2 -o %t.d/libtls.so --cache-dir %t.d/lib
// RUN: %kairo %S/Inputs/tls_loader.c --target=x86_64-linux-gnu -l dl -o %t.d/loader --cache-dir %t.d/ld
// RUN: %t.d/loader %t.d/libtls.so

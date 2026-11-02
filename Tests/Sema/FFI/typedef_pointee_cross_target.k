// One C typedef is one Kairo type in every position, and a pointer to a C
// integer alias reaches C++ as the type the header spelled.
//  - x86_64-windows-gnu: `pthread_t` is `uintptr_t`, which is `usize` as a
//    variable's type. As `pthread_t*` it was `unsafe *u64` (the pointee was
//    read canonical, past the typedef), so `pthread_create(unsafe &tid, ...)`
//    had no viable candidate (SC063E).
//  - i686-linux-musl: `pthread_t` is `unsigned long`, which is `u32`, whose
//    C++ spelling is `unsigned int`. `&tid` was `unsigned int*` passed to
//    `pthread_t*`, and clang rejected it (CL001E). The argument is now cast
//    to the parameter's own spelling.

ffi "c" import "pthread.h"

static seen: i32 = 0

fn worker(arg: unsafe *void) -> unsafe *void {
    seen = 42
    return arg
}

fn main() -> i32 {
    var tid: pthread_t
    unsafe { pthread_create(unsafe &tid, &null, worker, &null) }
    pthread_join(tid, &null)
    return seen
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-i686-linux-musl, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: { %kairo %s --target=x86_64-windows-gnu --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=WIN --allow-empty
// WIN-NOT: error
// RUN: %kairo %s --target=x86_64-windows-gnu -lpthread -o %t.d/w.exe
// RUN: test -s %t.d/w.exe

// RUN: { %kairo %s --target=i686-linux-musl --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=I686
// I686: ::pthread_create(reinterpret_cast<pthread_t *{{( restrict)?}}>((& tid)), nullptr,
// RUN: %kairo %s --target=i686-linux-musl -o %t.d/i686
// RUN: test -s %t.d/i686

// The host is unchanged: `pthread_t*` needs no cast where the alias is the
// natural integer.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=HOST
// HOST: ::pthread_create((& tid), nullptr,

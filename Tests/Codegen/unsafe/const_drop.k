// `as unsafe *T` may drop a pointee's `const`, and reinterpret_cast cannot:
// clang rejects it as casting away qualifiers. A drop is spelled as a C-style
// cast instead, here a `*const u8` handed to free as `unsafe *void` and a
// `*const i32` written through as `unsafe *i32`. A cast that only adds
// qualifiers keeps reinterpret_cast.
//
// Between two classes a C-style cast is a static_cast, which moves the
// pointer to a base at a nonzero offset. `as unsafe *` reinterprets with or
// without a drop, so that pair goes through `const volatile void *`: both
// casts to B below read D's first word, A's field.

ffi "c" import "stdlib.h"

class A { pub var a: i64 = 1 }
class B { pub var b: i64 = 2 }
class D derives A, B { pub var d: i64 = 3 }

fn main() -> i32 {
    var p: unsafe *const u8
    unsafe { p = malloc(4) as unsafe *const u8 }
    unsafe { free(p as unsafe *void) }

    var x: i32 = 3
    var q: *const i32 = &x
    var w: unsafe *i32
    unsafe { w = q as unsafe *i32 }
    unsafe { *w = 7 }

    var y = D()
    var pc: *const D = &y
    var pm: *D = &y
    var bc: unsafe *B
    var bm: unsafe *const B
    unsafe { bc = pc as unsafe *B }
    unsafe { bm = pm as unsafe *const B }
    var r: i64 = 0
    unsafe { r = (*bc).b * 10 + (*bm).b }

    return x * 10 + (r as i32)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// stderr is dropped: clang's "1 warning generated." for the base cast at
// line 35 is written while the dump is still being flushed, and lands
// inside whichever line straddles that byte offset.
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}const_drop.k
// IR:      reinterpret_cast<const unsigned char *>({{ ?}}::malloc(4))
// IR-NOT:  reinterpret_cast
// IR:      ::free((void *)(p));
// IR-NOT:  reinterpret_cast
// IR:      (w ={{ ?}}(signed int *)(q));
// IR-NOT:  reinterpret_cast
// IR:      (bc ={{ ?}}({{ ?}}::const_drop::B *)((const volatile void *)(pc)));
// IR:      (bm ={{ ?}}reinterpret_cast<const{{ ?}}::const_drop::B *>(pm));

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 81

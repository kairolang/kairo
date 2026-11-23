// A file of a program that sets its global allocator (`@set_global_allocator`
// somewhere, so this file is compiled with __KAIRO_GLOBAL_ALLOCATOR_SET)
// reaches the heap through the kairo_global_* symbols. AllocModel
// (Optimize/LLVM/AllocModel.k) annotates kairo_global_alloc,
// kairo_global_alloc_zeroed and kairo_global_free as it does the runtime
// heap's entry points, so above -O0 a block nothing uses is removed with
// its allocation and its free and never reaches the program's allocator.
// A block that escapes stays, and kairo_global_realloc is not annotated:
// a realloc whose result is only freed still runs.
//
// This file sets no allocator itself: --global-allocator-set is what a
// file of such a program is compiled with, and linked alone the symbols
// are the runtime's own (System), so the program runs and prints the same
// at -O0 and at -O2.

import builtin::base::alloc::*
import std::io::println

class Point {
    pub var x: i64
    pub var y: i64
    pub fn Point(self, x: i64, y: i64) { self.x = x; self.y = y }
}

// Never used, from Global by name.
fn dead(a: i64) -> i64 {
    var *p = @create(in: Global) Point(a, 2)
    @destroy(in: Global) p
    return a
}

// Never used, from the allocator in effect: Global when no scope is open.
fn plain_dead(a: i64) -> i64 {
    var *p = @create Point(a, 3)
    @destroy p
    return a
}

// Zeroed bytes, read back.
fn zeroed_read() -> i64 {
    var unsafe *p = @alloc_zeroed(size: 64, align: 8, in: Global)
    var v = unsafe (*(p as unsafe *i64))
    @free(size: 64, align: 8, in: Global) p
    return v
}

// Returned: the caller owns the block.
fn escapes(a: i64) -> *Point {
    return @create(in: Global) Point(a, 4)
}

@no_inline
fn fill(p: unsafe *u8, n: usize) -> i64 {
    var s: i64 = 0
    for var i: usize = 0; i < n; ++i {
        unsafe { *(p + i) = 7 }
        s += 7
    }
    return s
}

// The realloc's result is only freed.
fn regrown() -> i64 {
    var unsafe *p = @alloc(size: 16, align: 8, in: Global)
    var s = fill(p, 16)
    var unsafe *q = Global::realloc(p, 16, 64, 8)
    @free(size: 64, align: 8, in: Global) q
    return s
}

fn main() -> i32 {
    var *q = escapes(7)
    println(f"dead {dead(1)}")
    println(f"plain_dead {plain_dead(2)}")
    println(f"zeroed {zeroed_read()}")
    println(f"escapes {q->x + q->y}")
    println(f"regrown {regrown()}")
    @destroy(in: Global) q
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.on %t.off %t.o0 %t.o2 %t.exe
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --global-allocator-set --cache-dir %t.on
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --global-allocator-set --cache-dir %t.off --disable-kairo-pass=alloc-model
// RUN: %FileCheck %s --check-prefix=GONE < %t.on/alloc_model_global.ll
// RUN: %FileCheck %s --check-prefix=STAYS < %t.on/alloc_model_global.ll
// RUN: %FileCheck %s --check-prefix=STAYS < %t.off/alloc_model_global.ll
// RUN: %FileCheck %s --check-prefix=OFF < %t.off/alloc_model_global.ll

// GONE-LABEL: define {{.*}}@_ZN18alloc_model_global4deadEl(
// GONE-NOT:   call
// GONE:       {{^}}}
// GONE-LABEL: define {{.*}}@_ZN18alloc_model_global10plain_deadEl(
// GONE-NOT:   @kairo_global_alloc(
// GONE:       {{^}}}
// GONE-LABEL: define {{.*}}@_ZN18alloc_model_global11zeroed_readEv(
// GONE-NOT:   call
// GONE:       ret i64 0
// GONE-NEXT:  {{^}}}

// STAYS-LABEL: define {{.*}}@_ZN18alloc_model_global7escapesEl(
// STAYS-NOT:   {{^}}}
// STAYS:       call {{.*}}@kairo_global_alloc(
// STAYS:       {{^}}}
// STAYS-LABEL: define {{.*}}@_ZN18alloc_model_global7regrownEv(
// STAYS-NOT:   {{^}}}
// STAYS:       call {{.*}}@kairo_global_alloc(
// STAYS-NOT:   {{^}}}
// STAYS:       call {{.*}}@kairo_global_realloc(
// STAYS-NOT:   {{^}}}
// STAYS:       call void @kairo_global_free(
// STAYS:       {{^}}}

// OFF-LABEL: define {{.*}}@_ZN18alloc_model_global4deadEl(
// OFF-NOT:   {{^}}}
// OFF:       call {{.*}}@kairo_global_alloc(
// OFF-NOT:   {{^}}}
// OFF:       call void @kairo_global_free(
// OFF:       {{^}}}
// OFF-LABEL: define {{.*}}@_ZN18alloc_model_global10plain_deadEl(
// OFF-NOT:   {{^}}}
// OFF:       call {{.*}}@kairo_global_alloc(
// OFF:       {{^}}}

// RUN: %kairo %s -O0 --global-allocator-set -o %t.exe --cache-dir %t.o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 --global-allocator-set -o %t.exe --cache-dir %t.o2
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT:      dead 1
// OUT-NEXT: plain_dead 2
// OUT-NEXT: zeroed 0
// OUT-NEXT: escapes 11
// OUT-NEXT: regrown 112

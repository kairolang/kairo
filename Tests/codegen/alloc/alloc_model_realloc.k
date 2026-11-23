// A realloc across a size class, whose result only the free uses. The frees
// are sized and the runtime picks one from the size, so the block must reach
// the free its new size selects: LLVM may not drop the realloc and hand the
// old block to that free. A shrink takes a large mapped block to the small
// range, a grow takes a small-page block to a large one.

import builtin::base::alloc::*
import std::io::println

@no_inline
fn fill(p: unsafe *u8, n: usize) -> i64 {
    var s: i64 = 0
    for var i: usize = 0; i < n; ++i {
        unsafe { *(p + i) = 7 }
        s += 7
    }
    return s
}

fn shrink() -> i64 {
    var unsafe *p = @alloc(size: 1048576, align: 8, in: Global)
    var s = fill(p, 2000)
    var unsafe *q = Global::realloc(p, 1048576, 16, 8)
    @free(size: 16, align: 8, in: Global) q
    return s
}

fn grow() -> i64 {
    var unsafe *p = @alloc(size: 16, align: 8, in: Global)
    var s = fill(p, 16)
    var unsafe *q = Global::realloc(p, 16, 1048576, 8)
    @free(size: 1048576, align: 8, in: Global) q
    return s
}

fn main() -> i32 {
    println(f"shrink {shrink()}")
    println(f"grow {grow()}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.ir %t.o0 %t.o2 %t.exe
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.ir
// RUN: %FileCheck %s --check-prefix=IR < %t.ir/alloc_model_realloc.ll

// IR-LABEL: define {{.*}}@_ZN19alloc_model_realloc6shrinkEv(
// IR:       call {{.*}}@{{kairo_rt_heap_realloc|_ZN7builtin9alloc_raw6System7realloc[A-Za-z0-9_]*}}(
// IR:       {{^}}}
// IR-LABEL: define {{.*}}@_ZN19alloc_model_realloc4growEv(
// IR:       call {{.*}}@{{kairo_rt_heap_realloc|_ZN7builtin9alloc_raw6System7realloc[A-Za-z0-9_]*}}(
// IR:       {{^}}}

// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.o2
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT:      shrink 14000
// OUT-NEXT: grow 112

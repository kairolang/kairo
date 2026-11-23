// A plain `@create` / `@destroy` chooses its allocator at run time: the
// innermost open scope's, else the global heap. Above -O0 AllocSplit
// (Optimize/LLVM/AllocSplit.k) gives the global heap a path of its own
// through a function that holds both, when nothing between them can open
// or close a scope. On that path the block is the heap's own, so an
// allocation nothing uses is removed with its free, as for
// `@create(in: Global)`. The open scope's path keeps its two calls.
//
// What is checked, per function, at -O2:
//   unused, read_only   the global path allocates nothing; the scope's
//                       path still calls the scope's allocator and frees
//                       through it
//   churn               the same inside a loop, which is not copied twice
//   escapes_as_int      the block's address is kept, so the block stays:
//                       one direct allocation and one direct free
//   observed            a call between the two may open a scope: no split
//   resized             a resize between the two is not an allocation
//                       LLVM pairs: nothing is removed
//   scoped              inside `@set_scoped_allocator` the arena's calls stay
// and that --disable-kairo-pass=alloc-split, or alloc-model (the split
// needs its annotations), leaves the allocation in place.
//
// The program prints the same at -O0 and at -O2, the arena's counts
// included: a scoped allocator's calls are never removed.

import builtin::base::alloc::*
import std::io::println

class Point {
    pub var x: i64
    pub var y: i64
    pub fn Point(self, x: i64, y: i64) { self.x = x; self.y = y }
}

static seen:  usize = 0
static total: i64   = 0

static arena:       [u8; 4096]
static cursor:      usize = 0
static bump_allocs: i32   = 0
static bump_frees:  i32   = 0

fn arena_base() -> unsafe *u8 { unsafe { return &arena[0] as unsafe *u8 } }

class Bump {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        var at = align_up(cursor, align)
        cursor = at + size
        bump_allocs += 1
        return arena_base() + at
    }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { bump_frees += 1 }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
        return realloc_by_copy<Bump>(ptr, o, n, align)
    }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        var unsafe *p = Bump::alloc(size, align)
        __builtin_set_mem(p, 0 as byte, size)
        return p
    }
    pub static fn enter() -> usize { return cursor }
    pub static fn leave(m: usize) { cursor = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (arena_base(), arena_base() + 4096) }
}

fn unused(a: i64) -> i64 {
    var *p = @create Point(a, 2)
    @destroy p
    return a
}

fn read_only(a: i64) -> i64 {
    var *p = @create Point(a, a + 1)
    var r = p->x + p->y
    @destroy p
    return r
}

fn churn(n: i64) -> i64 {
    var sum: i64 = 0
    for var i: i64 = 0; i < n; i += 1 {
        var *p = @create Point(i, 2)
        sum += p->x + p->y
        @destroy p
    }
    return sum
}

fn escapes_as_int(a: i64) -> i64 {
    var *p = @create Point(a, 3)
    seen = unsafe (p as unsafe *Point) as usize
    var r = p->x + p->y
    @destroy p
    return r
}

@no_inline
fn observe(p: *Point) { total += p->x }

fn observed(a: i64) -> i64 {
    var *p = @create Point(a, 4)
    observe(p)
    @destroy p
    return a
}

fn resized(a: i64) -> i64 {
    var unsafe *p = alloc_raw(16, 8)
    unsafe { *(p as unsafe *i64) = a }
    p = resize_raw(p, 16, 4096, 8)
    var r = unsafe (*(p as unsafe *i64))
    free_raw(p, 4096, 8)
    return r
}

fn scoped(a: i64) -> i64 {
    var r: i64 = 0
    @set_scoped_allocator(Bump) {
        var *p = @create Point(a, 6)
        r = p->x + p->y
        @destroy p
    }
    return r
}

fn main() -> i32 {
    println(f"unused {unused(1)}")
    println(f"read_only {read_only(3)}")
    println(f"churn {churn(10)}")
    println(f"escapes_as_int {escapes_as_int(7)} {seen != 0}")
    println(f"observed {observed(8)} {total}")
    println(f"resized {resized(9)}")
    println(f"scoped {scoped(10)} allocs {bump_allocs} frees {bump_frees}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.on %t.nosplit %t.nomodel %t.o0 %t.o2 %t.exe
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.on
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.nosplit --disable-kairo-pass=alloc-split
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.nomodel --disable-kairo-pass=alloc-model
// RUN: %FileCheck %s --check-prefix=SPLIT < %t.on/alloc_split.ll
// RUN: %FileCheck %s --check-prefix=ARM < %t.on/alloc_split.ll
// RUN: %FileCheck %s --check-prefix=OFF --implicit-check-not=kairo.alloc.split < %t.nosplit/alloc_split.ll
// RUN: %FileCheck %s --check-prefix=OFF --implicit-check-not=kairo.alloc.split < %t.nomodel/alloc_split.ll

// The global heap's path: no allocation where the block is unused, one
// direct allocation and free with no second test of the stack where it is
// kept, and the function as it was where a call or a resize sits between.
// SPLIT-LABEL: define {{.*}}@_ZN11alloc_split6unusedEl(
// SPLIT-NOT:   @mi_malloc_small(
// SPLIT:       {{^}}}
// SPLIT-LABEL: define {{.*}}@_ZN11alloc_split9read_onlyEl(
// SPLIT-NOT:   @mi_malloc_small(
// SPLIT:       {{^}}}
// SPLIT-LABEL: define {{.*}}@_ZN11alloc_split5churnEl(
// SPLIT-NOT:   @mi_malloc_small(
// SPLIT:       {{^}}}
// SPLIT-LABEL: define {{.*}}@_ZN11alloc_split14escapes_as_intEl(
// SPLIT-NOT:   {{^}}}
// SPLIT:       %[[P:[A-Za-z0-9_.]+]] = {{.*}}call {{.*}}@mi_malloc_small(i64 noundef 16)
// SPLIT-NOT:   = load ptr,
// SPLIT:       call void @mi_free_small_nonnull(ptr {{.*}}%[[P]])
// SPLIT:       {{^}}}
// SPLIT-LABEL: define {{.*}}@_ZN11alloc_split8observedEl(
// SPLIT-NOT:   {{^}}}
// SPLIT:       call {{.*}}@mi_malloc_small(
// SPLIT-NOT:   {{^}}}
// SPLIT:       call void @_ZN11alloc_split7observeEPNS_5PointE(
// SPLIT-NOT:   {{^}}}
// SPLIT:       = load ptr, ptr %{{[0-9a-z.]+}}
// SPLIT-NOT:   {{^}}}
// SPLIT:       call void @mi_free_small_nonnull(
// SPLIT:       {{^}}}
// SPLIT-LABEL: define {{.*}}@_ZN11alloc_split7resizedEl(
// SPLIT-NOT:   {{^}}}
// SPLIT:       call {{.*}}@mi_malloc_small(
// SPLIT-NOT:   {{^}}}
// SPLIT:       call {{.*}}@_ZN7builtin9alloc_raw10resize_rawEPhmmm(
// SPLIT-NOT:   {{^}}}
// SPLIT:       = load ptr, ptr %{{[0-9a-z.]+}}
// SPLIT-NOT:   {{^}}}
// SPLIT:       call void @mi_free(
// SPLIT:       {{^}}}

// The open scope's path: its allocator's call and the free through the
// scope stack, once each.
// ARM-LABEL: define {{.*}}@_ZN11alloc_split6unusedEl(
// ARM-NOT:   {{^}}}
// ARM:       call noundef ptr %{{[0-9a-z.]+}}(i64 noundef 16, i64 noundef 8)
// ARM-NOT:   {{^}}}
// ARM:       call void @_ZN7builtin9alloc_raw11free_scopedEPhmm(
// ARM:       {{^}}}
// ARM-LABEL: define {{.*}}@_ZN11alloc_split5churnEl(
// ARM-NOT:   {{^}}}
// ARM:       call noundef ptr %{{[0-9a-z.]+}}(i64 noundef 16, i64 noundef 8)
// ARM-NOT:   call noundef ptr %{{[0-9a-z.]+}}(i64 noundef 16, i64 noundef 8)
// ARM:       {{^}}}
// ARM-LABEL: define {{.*}}@_ZN11alloc_split6scopedEl(
// ARM-NOT:   {{^}}}
// ARM:       call {{.*}}@_ZN7builtin9alloc_raw10scope_push
// ARM-NOT:   {{^}}}
// ARM:       call noundef ptr %{{[0-9a-z.]+}}(i64 noundef 16, i64 noundef 8)
// ARM-NOT:   {{^}}}
// ARM:       call void @_ZN7builtin9alloc_raw11free_scopedEPhmm(
// ARM:       {{^}}}

// With either pass off the allocation and its free stay, behind the two
// tests.
// OFF-LABEL: define {{.*}}@_ZN11alloc_split6unusedEl(
// OFF-NOT:   {{^}}}
// OFF:       call {{.*}}@mi_malloc_small(
// OFF-NOT:   {{^}}}
// OFF:       call void @mi_free_small_nonnull(
// OFF:       {{^}}}
// OFF-LABEL: define {{.*}}@_ZN11alloc_split5churnEl(
// OFF-NOT:   {{^}}}
// OFF:       call {{.*}}@mi_malloc_small(
// OFF:       {{^}}}

// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.o2
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT:      unused 1
// OUT-NEXT: read_only 7
// OUT-NEXT: churn 65
// OUT-NEXT: escapes_as_int 10 true
// OUT-NEXT: observed 8 8
// OUT-NEXT: resized 9
// OUT-NEXT: scoped 16 allocs 1 frees 1

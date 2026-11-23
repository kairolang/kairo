// Above -O0 AllocModel (Optimize/LLVM/AllocModel.k) tells LLVM that the
// runtime heap's entry points allocate, free and reallocate as malloc, free
// and realloc do. So at -O2 a global-heap block that nothing outside its
// function sees is removed with its allocation and its free, a zeroed
// block reads as zero, and a store into a block that is freed next is dead.
//
// A block the function does not own outright stays: one returned, one
// stored in a global. So does every block whose allocator is chosen at run
// time: a plain `@create` (from the innermost open scope, else the global
// heap) and a scoped arena's. Those shapes are checked twice under the same
// lines, with the pass on and with --disable-kairo-pass=alloc-model.
//
// The program prints the same at -O0 and at -O2.

import builtin::base::alloc::*
import std::io::println

class Point {
    pub var x: i64
    pub var y: i64
    pub fn Point(self, x: i64, y: i64) { self.x = x; self.y = y }
}

static keep: unsafe *Point = &null

// A bump arena for the scoped shape, counting what reaches it.
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

// Read only, then destroyed: nothing of the block is left.
fn read_only(a: i64) -> i64 {
    var *p = @create(in: Global) Point(a, a + 1)
    var r = p->x + p->y
    @destroy(in: Global) p
    return r
}

// Never used.
fn dead(a: i64) -> i64 {
    var *p = @create(in: Global) Point(a, 2)
    @destroy(in: Global) p
    return a
}

// Zeroed bytes, read back: the read is a zero.
fn zeroed_read() -> i64 {
    var unsafe *p = @alloc_zeroed(size: 64, align: 8, in: Global)
    var v = unsafe (*(p as unsafe *i64))
    @free(size: 64, align: 8, in: Global) p
    return v
}

// A large block and an over-aligned one, never used.
fn large_dead() {
    var unsafe *p = @alloc(size: 1048576, align: 16, in: Global)
    @free(size: 1048576, align: 16, in: Global) p
}

fn aligned_dead() {
    var unsafe *p = @alloc(size: 64, align: 64, in: Global)
    @free(size: 64, align: 64, in: Global) p
}

// A store into a block that is freed next is dead; the free stays, since
// the block is the caller's.
fn store_then_free(p: unsafe *u8) {
    unsafe { *(p as unsafe *i64) = 42 }
    @free(size: 8, align: 8, in: Global) p
}

// Returned: the caller owns the block.
fn escapes(a: i64) -> *Point {
    return @create(in: Global) Point(a, 3)
}

// Stored in a global.
fn published(a: i64) {
    var *p = @create(in: Global) Point(a, 4)
    keep = unsafe (p as unsafe *Point)
}

// The allocator is chosen at run time, from the scope stack.
fn plain(a: i64) -> i64 {
    var *p = @create Point(a, 5)
    var r = p->x + p->y
    @destroy p
    return r
}

// From the open scope's arena.
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
    var unsafe *b = @alloc(size: 8, align: 8, in: Global)
    store_then_free(b)
    large_dead()
    aligned_dead()
    var *q = escapes(7)
    published(8)
    println(f"read_only {read_only(3)}")
    println(f"dead {dead(4)}")
    println(f"zeroed {zeroed_read()}")
    println(f"escapes {q->x + q->y}")
    var kept = unsafe (keep->y)
    println(f"published {kept}")
    println(f"plain {plain(9)}")
    println(f"scoped {scoped(10)} allocs {bump_allocs} frees {bump_frees}")
    @destroy(in: Global) q
    @destroy(in: Global) unsafe (keep as *Point)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.on %t.off %t.o0 %t.o2 %t.exe
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.on
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.off --disable-kairo-pass=alloc-model
// RUN: %FileCheck %s --check-prefix=GONE < %t.on/alloc_model.ll
// RUN: %FileCheck %s --check-prefix=STAYS < %t.on/alloc_model.ll
// RUN: %FileCheck %s --check-prefix=STAYS < %t.off/alloc_model.ll
// RUN: %FileCheck %s --check-prefix=OFF < %t.off/alloc_model.ll

// GONE-LABEL: define {{.*}}@_ZN11alloc_model9read_onlyEl(
// GONE-NOT:   call
// GONE:       {{^}}}
// GONE-LABEL: define {{.*}}@_ZN11alloc_model4deadEl(
// GONE-NOT:   call
// GONE:       {{^}}}
// GONE-LABEL: define {{.*}}@_ZN11alloc_model11zeroed_readEv(
// GONE-NOT:   call
// GONE:       ret i64 0
// GONE-LABEL: define {{.*}}@_ZN11alloc_model10large_deadEv(
// GONE-NOT:   call
// GONE:       {{^}}}
// GONE-LABEL: define {{.*}}@_ZN11alloc_model12aligned_deadEv(
// GONE-NOT:   call
// GONE:       {{^}}}
// GONE-LABEL: define {{.*}}@_ZN11alloc_model15store_then_freeEPh(
// GONE-NOT:   store
// GONE:       call void @mi_free_small_nonnull(
// GONE:       {{^}}}

// OFF-LABEL: define {{.*}}@_ZN11alloc_model9read_onlyEl(
// OFF:       call {{.*}}@mi_malloc_small(
// OFF:       call void @mi_free_small_nonnull(
// OFF-LABEL: define {{.*}}@_ZN11alloc_model15store_then_freeEPh(
// OFF:       store i64 42
// OFF:       call void @mi_free_small_nonnull(

// STAYS-LABEL: define {{.*}}@_ZN11alloc_model7escapesEl(
// STAYS:       call {{.*}}@mi_malloc_small(
// STAYS:       {{^}}}
// STAYS-LABEL: define {{.*}}@_ZN11alloc_model9publishedEl(
// STAYS:       call {{.*}}@mi_malloc_small(
// STAYS:       store ptr %{{.*}}, ptr @_ZN11alloc_model4keepE
// STAYS:       {{^}}}
// STAYS-LABEL: define {{.*}}@_ZN11alloc_model5plainEl(
// STAYS:       call {{.*}}@mi_malloc_small(
// STAYS:       call noundef ptr %{{[0-9a-z.]+}}(i64 noundef 16, i64 noundef 8)
// STAYS:       call void @mi_free_small_nonnull(
// STAYS:       call void @_ZN7builtin9alloc_raw11free_scopedEPhmm(
// STAYS:       {{^}}}
// STAYS-LABEL: define {{.*}}@_ZN11alloc_model6scopedEl(
// STAYS:       call {{.*}}@_ZN7builtin9alloc_raw10scope_push
// STAYS:       call {{.*}}@mi_malloc_small(
// STAYS:       call noundef ptr %{{[0-9a-z.]+}}(i64 noundef 16, i64 noundef 8)
// STAYS:       call void @mi_free_small_nonnull(
// STAYS:       call void @_ZN7builtin9alloc_raw11free_scopedEPhmm(
// STAYS:       {{^}}}

// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.o2
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT:      read_only 7
// OUT-NEXT: dead 4
// OUT-NEXT: zeroed 0
// OUT-NEXT: escapes 10
// OUT-NEXT: published 4
// OUT-NEXT: plain 14
// OUT-NEXT: scoped 16 allocs 1 frees 1

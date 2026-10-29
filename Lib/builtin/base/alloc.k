/// --- The Kairo Project ---------------------------- Lib/builtin/alloc.k --- ///
///
///   \brief The allocator model: the Allocator interfaces, typed uninitialized
///          storage, the allocation front end, the OOM hook, and the two
///          allocators the language ships with (System and Arena).
///
///   \detail
///     Three layers, each knowing only about the one below it:
///       - an allocator hands out bytes (alloc / free) and never sees a type;
///       - Uninit<T> / UninitSlice<T> is storage typed as T that is not yet
///         a T: the only way to get a *T from it is to construct into it;
///       - @create / @destroy are mem::create / mem::destroy with the
///         allocator in effect (@A) filled in by the compiler.
///     Contract every allocator can rely on (the front end guarantees it):
///       - align is a power of two, size is never 0;
///       - free receives the size and align the block was made with (or the
///         new_size of the last successful resize / realloc), never null;
///       - a failed resize / realloc leaves the original block untouched.
///     Contract every allocator must keep:
///       - failure is &null: no abort, no panic (OOM policy is the front end's);
///       - a global allocator is thread-safe; a scoped one is used by one
///         thread only;
///       - a scoped allocator returns only pointers inside range() for as
///         long as the scope is open.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import builtin::base::intrinsics::*;
ffi "c++" import "rt/alloc.h"

// --- interfaces -------------------------------------------------------------

/// Everything a type must have to be used as an allocator.
pub interface Allocator {
    static fn alloc(size: usize, align: usize) -> unsafe *u8
    static fn free(ptr: unsafe *u8, size: usize, align: usize)
}

/// Grows or shrinks a block without moving it. false: nothing changed.
pub interface Resizer derives Allocator {
    static fn resize(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> bool
}

/// Grows or shrinks a block, moving it if it has to. &null: nothing changed.
/// Worth having only where a move is cheaper than alloc + copy + free.
pub interface Reallocator derives Allocator {
    static fn realloc(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8
}

/// Zeroed memory, for allocators that get it for free (fresh pages, calloc).
pub interface ZeroAllocator derives Allocator {
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8
}

/// What @mem::set_scoped_allocator takes. enter() runs on scope entry,
/// leave(mark) on every exit, unwinding included.
pub interface ScopedAllocator derives Allocator {
    type Mark
    static fn enter() -> Self::Mark
    static fn leave(mark: Self::Mark)
    static fn range() -> (unsafe *u8, unsafe *u8)
}

// --- helpers ----------------------------------------------------------------

pub inline fn is_pow2(v: usize) -> bool { return v != 0 && (v & (v - 1)) == 0 }

pub inline fn align_up(v: usize, align: usize) -> usize { return (v + align - 1) & ~(align - 1) }

/// A non-null, aligned pointer that owns nothing: what a zero-size request gets.
pub inline fn dangling(align: usize) -> unsafe *u8 { unsafe { return align as unsafe *u8 } }

// --- out of memory ----------------------------------------------------------

static oom_handler: fn(usize, usize) -> ! = default_oom

fn default_oom(size: usize, align: usize) -> ! {
    var msg = "kairo: out of memory"
    __builtin_crash(msg.data, msg.lenz, 134)
}

/// Replaces what @create does when the allocator returns &null.
pub fn set_oom_handler(h: fn(usize, usize) -> !) { oom_handler = h }

pub fn oom(size: usize, align: usize) -> ! { oom_handler(size, align) }

// --- typed uninitialized storage --------------------------------------------

/// Storage for one T that holds no T. Move-only. Turn it into an object with
/// construct, or give it back with mem::release.
pub struct <T> Uninit {
    priv var ptr: unsafe *u8

    /// Builds a T in the storage. The only safe way to a *T.
    pub fn <...A> construct(move self, ...args: A) -> *T {
        return __builtin_construct_at<T>(self.ptr, args...)
    }

    /// For a T whose bytes have all been written through as_bytes. Only for
    /// types that come into being when their bytes are written.
    pub fn assume_init(move self) -> *T
        requires __builtin_is_trivially_copyable<T>() && __builtin_is_trivially_destructible<T>()
    {
        unsafe { return __builtin_launder(self.ptr as unsafe *T) as *T }
    }

    pub fn as_bytes(const self) -> unsafe *u8 { return self.ptr }

    /// Reinterprets the storage for a U of the same or smaller size and
    /// alignment. Nothing lives in it either way.
    pub fn <U> retype(move self) -> Uninit<U>
        requires sizeof U <= sizeof T && alignof U <= alignof T
    {
        return Uninit<U> { ptr: self.ptr }
    }

    /// Wraps raw bytes. The caller vouches for size and alignment.
    pub unsafe fn from_bytes(ptr: unsafe *u8) -> Uninit<T> { return Uninit<T> { ptr: ptr } }
}

/// Runs the destructor and hands the storage back.
pub fn <T> uninit_from(move p: *T) -> Uninit<T> {
    __builtin_destruct_at(p)
    unsafe { return Uninit<T> { ptr: p as unsafe *u8 } }
}

/// Storage for cap Ts, of which [0, len) are live. Unwinding or dropping it
/// destroys only the live prefix; the storage itself goes back via release.
pub struct <T> UninitSlice {
    priv var ptr: unsafe *u8
    priv var cap: usize
    priv var len: usize

    pub fn size(const self) -> usize { return self.len }
    pub fn capacity(const self) -> usize { return self.cap }

    pub fn <...A> push(self, ...args: A) {
        if __builtin_expect(self.len == self.cap, false) { __builtin_trap() }
        unsafe { __builtin_construct_at<T>(self.ptr + self.len * sizeof T, args...) }
        self.len += 1
    }

    /// Every slot is live: the slice is now a slice of T.
    pub fn finish(move self) -> [*T] {
        if self.len != self.cap { __builtin_trap() }
        var p = self.ptr
        self.len = 0                            // ownership moves to the result
        unsafe { return (p as unsafe *T)[0..self.cap] }
    }

    pub fn as_bytes(const self) -> unsafe *u8 { return self.ptr }

    fn op delete(self) {
        var i: usize = self.len
        while i > 0 {
            i -= 1
            unsafe { __builtin_destruct_at((self.ptr as unsafe *T) + i) }
        }
    }
}

// --- the front end ----------------------------------------------------------
// Allocators implement only what they can do well; everything else is done
// here once, chosen at compile time. Zero-size requests never reach them.

pub fn <A impl Allocator> alloc_bytes(size: usize, align: usize) -> unsafe *u8 {
    if size == 0 { return dangling(align) }
    return A::alloc(size, align)
}

pub fn <A impl Allocator> free_bytes(ptr: unsafe *u8, size: usize, align: usize) {
    if size == 0 { return }
    A::free(ptr, size, align)
}

pub fn <A impl Allocator> alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
    if size == 0 { return dangling(align) }
    eval if A impl ZeroAllocator { return A::alloc_zeroed(size, align) }
    var p = A::alloc(size, align)
    if p != &null { __builtin_set_mem(p, 0, size) }
    return p
}

/// In place if the allocator can, else move. &null: nothing changed.
pub fn <A impl Allocator> resize_bytes(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 {
    if old_size == 0 { return alloc_bytes<A>(new_size, align) }
    if new_size == 0 { A::free(ptr, old_size, align); return dangling(align) }
    eval if A impl Resizer {
        if A::resize(ptr, old_size, new_size, align) { return ptr }
    }
    eval if A impl Reallocator {
        return A::realloc(ptr, old_size, new_size, align)
    }
    var n = A::alloc(new_size, align)
    if n == &null { return &null }
    __builtin_copy(n, ptr, if old_size < new_size { old_size } else { new_size })
    A::free(ptr, old_size, align)
    return n
}

/// Grows only without moving. For containers holding objects that are not
/// trivially relocatable.
pub fn <A impl Allocator> try_resize_in_place(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> bool {
    eval if A impl Resizer { return A::resize(ptr, old_size, new_size, align) }
    return false
}

pub fn <T, A impl Allocator> alloc() -> Uninit<T>? {
    var p = alloc_bytes<A>(sizeof T, alignof T)
    if p == &null { return null }
    return Uninit<T> { ptr: p }
}

pub fn <T, A impl Allocator> alloc_slice(n: usize) -> UninitSlice<T>? {
    var bytes: usize = 0
    if __builtin_mul_overflow(n, sizeof T, &bytes) { return null }
    var p = alloc_bytes<A>(bytes, alignof T)
    if p == &null { return null }
    return UninitSlice<T> { ptr: p, cap: n, len: 0 }
}

pub fn <T, A impl Allocator> release(move u: Uninit<T>) {
    free_bytes<A>(u.as_bytes(), sizeof T, alignof T)
}

/// Destroys what is live, then frees the storage.
pub fn <T, A impl Allocator> release_slice(move s: UninitSlice<T>) {
    var p = s.as_bytes()
    var c = s.capacity()
    delete s
    free_bytes<A>(p, c * sizeof T, alignof T)
}

/// @create T(args...): allocate, construct, give the storage back if the
/// constructor throws. The compiler passes the allocator in effect as A.
pub fn <T, A impl Allocator, ...Args> create(...args: Args) -> *T {
    var u = alloc<T, A>()
    if __builtin_expect(u == null, false) { oom(sizeof T, alignof T) }
    var s = unwrap!(u)
    try {
        return s.construct(args...)
    } catch {
        release<T, A>(s)
        rethrow
    }
}

/// @try_create T(args...): null instead of the OOM hook.
pub fn <T, A impl Allocator, ...Args> try_create(...args: Args) -> *T? {
    var u = alloc<T, A>()
    if u == null { return null }
    var s = unwrap!(u)
    try {
        return s.construct(args...)
    } catch {
        release<T, A>(s)
        rethrow
    }
}

/// @destroy p: destruct, then free, as one step.
pub fn <T, A impl Allocator> destroy(move p: *T) {
    release<T, A>(uninit_from(p))
}

// --- System: the default global allocator -----------------------------------
// The platform's malloc, so memory that crosses into C++ and every sanitizer
// and heap profiler see the same heap.

eval const MAX_ALIGN: usize = kairo_rt_malloc_align()

pub class System {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        if __builtin_expect(align <= MAX_ALIGN, true) { return kairo_rt_malloc(size) }
        return kairo_rt_aligned_alloc(align_up(size, align), align)
    }

    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        if __builtin_expect(align <= MAX_ALIGN, true) { return kairo_rt_calloc(size) }
        var p = kairo_rt_aligned_alloc(align_up(size, align), align)
        if p != &null { __builtin_set_mem(p, 0, size) }
        return p
    }

    static fn realloc(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 {
        if __builtin_expect(align <= MAX_ALIGN, true) { return kairo_rt_realloc(ptr, new_size) }
        var n = kairo_rt_aligned_alloc(align_up(new_size, align), align)
        if n == &null { return &null }
        __builtin_copy(n, ptr, if old_size < new_size { old_size } else { new_size })
        kairo_rt_aligned_free(ptr, old_size, align)
        return n
    }

    static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        if __builtin_expect(align <= MAX_ALIGN, true) { kairo_rt_free(ptr, size); return }
        kairo_rt_aligned_free(ptr, size, align)
    }
}

// --- Arena: the default scoped allocator ------------------------------------
// A bump allocator over one per-thread address-space reservation. Pages are
// committed as the cursor reaches them. leave() rewinds to the mark; nothing
// is returned to the OS until the thread ends.

eval const ARENA_RESERVE: usize = if __builtin_target_info().is_wasm() =>
    1 << 24 // 16 MiB, taken up front
else if __builtin_target_info().is_64bit() =>
    1 << 32
else =>
    1 << 26 // 64 MiB on 32-bit

eval const ARENA_COMMIT: usize = 1 << 16          // a multiple of every page size: 4K, 16K (Apple arm64), 64K (some aarch64 kernels)

pub class Arena {
    thread_local static var base:      unsafe *u8 = &null
    thread_local static var cur:       unsafe *u8 = &null
    thread_local static var committed: unsafe *u8 = &null

    type Mark = unsafe *u8

    static fn range() -> (unsafe *u8, unsafe *u8) {
        return (Arena::base, Arena::base + ARENA_RESERVE)
    }

    static fn enter() -> Self::Mark {
        if __builtin_expect(Arena::base == &null, false) {
            Arena::base      = kairo_rt_reserve(ARENA_RESERVE)
            Arena::cur       = Arena::base
            Arena::committed = Arena::base
        }
        return Arena::cur
    }

    static fn leave(mark: Self::Mark) { Arena::cur = mark }

    static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        if __builtin_expect(Arena::base == &null, false) { return &null }
        var p = align_up(Arena::cur as usize, align) as unsafe *u8
        if !Arena::reach(p + size) { return &null }
        Arena::cur = p + size
        return __builtin_assume_aligned(p, align)
    }

    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        var p = Arena::alloc(size, align)
        if p != &null { __builtin_set_mem(p, 0, size) }     // rewound memory is not fresh
        return p
    }

    /// Only the newest block moves the cursor; the rest wait for leave().
    static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        if ptr + size == Arena::cur { Arena::cur = ptr }
    }

    /// The newest block grows or shrinks in place; any other block can only shrink.
    static fn resize(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> bool {
        if ptr + old_size != Arena::cur { return new_size <= old_size }
        if !Arena::reach(ptr + new_size) { return false }
        Arena::cur = ptr + new_size
        return true
    }

    priv static fn reach(end: unsafe *u8) -> bool {
        if __builtin_expect(end <= Arena::committed, true) { return true }
        if end > Arena::base + ARENA_RESERVE { return false }
        var to = (Arena::base as usize + align_up(end - Arena::base, ARENA_COMMIT)) as unsafe *u8
        if !kairo_rt_commit(Arena::committed, to - Arena::committed) { return false }
        Arena::committed = to
        return true
    }
}
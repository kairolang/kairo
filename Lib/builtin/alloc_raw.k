/// --- The Kairo Project ------------------------- Lib/builtin/alloc_raw.k --- ///
///
///   \brief The allocator model's byte layer: the allocator interfaces, the
///          OOM hook, the global allocator (Global, System), the per-thread
///          scope stack AllocatorScope (base/alloc.k) pushes and pops, and
///          the current-allocator family alloc_raw / free_raw / resize_raw.
///
///   \detail
///     Split out of base/alloc.k so a builtin type can own memory: it
///     imports neither the builtin root nor string, so string.k (which the
///     root imports) can allocate through it without an import cycle.
///     alloc.k `pub import`s it, so std::mem and every user of
///     builtin::base::alloc see the same API as before. The contracts are
///     alloc.k's (see its header). Nothing here may use a string literal,
///     `T?` or another lang item the root declares; so an `assert` here has
///     no message (its message is typed `string`) and says why in a
///     comment, which the crash text quotes with the condition.
///
///     At the builtin root, not in base/: a program's objects mirror the
///     module tree, and code that links builtin/*.o by hand (the lit tests,
///     kcc users) then gets it beside string.o, which needs it.
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
pub interface Reallocator derives Allocator {
    static fn realloc(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8
}

/// Zeroed memory, for allocators that get it for free (fresh pages, calloc).
pub interface ZeroAllocator derives Allocator {
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8
}

/// Used with AllocatorScope. enter()
/// returns a token that leave() takes back; range() is the address range
/// every block it hands out lies in while the scope is open.
pub interface ScopedAllocator derives Allocator {
    static fn enter() -> usize
    static fn leave(mark: usize)
    static fn range() -> (unsafe *u8, unsafe *u8)
}

/// What the front end and @set_global_allocator take, until eval if can test a
/// capability per instantiation; then the front end takes Allocator and
/// falls back where a capability is missing.
pub interface FullAllocator derives Resizer + Reallocator + ZeroAllocator { }

/// What AllocatorScope takes.
pub interface ScopedFullAllocator derives ScopedAllocator + FullAllocator { }

// --- helpers ----------------------------------------------------------------

pub inline fn is_pow2(v: usize) -> bool { return v != 0 && (v & (v - 1)) == 0 }

pub inline fn align_up(v: usize, align: usize) -> usize { return (v + align - 1) & ~(align - 1) }

/// A non-null, aligned pointer that owns nothing: what a zero-size request gets.
pub inline fn dangling(align: usize) -> unsafe *u8 { unsafe { return align as unsafe *u8 } }


/// realloc for an allocator with no faster path: alloc, copy, free.
pub fn <A impl Allocator> realloc_by_copy(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 {
    var unsafe *n = A::alloc(new_size, align)
    if n == &null { return &null }
    __builtin_copy(n, ptr, if old_size < new_size => old_size else => new_size)
    A::free(ptr, old_size, align)
    return n
}

// --- out of memory ----------------------------------------------------------

static oom_handler: fn(usize, usize) -> ! = default_oom

/// The message as bytes, not a string literal: this file sits below the
/// string lang item (string.k allocates through it), so it cannot name one.
static OOM_MSG: [u8; 20] = [107, 97, 105, 114, 111, 58, 32, 111, 117, 116, 32, 111, 102, 32, 109, 101, 109, 111, 114, 121]   // "kairo: out of memory"

fn default_oom(size: usize, align: usize) -> ! {
    __builtin_crash(&OOM_MSG[0], 20, 134)
}

/// Replaces what create does when the allocator returns &null.
pub fn set_oom_handler(h: fn(usize, usize) -> !) { oom_handler = h }

/// Runs the handler. The handler is typed -> !, and the compiler emits
/// __builtin_unreachable after a call through a -> ! fn value.
pub fn oom(size: usize, align: usize) -> ! {
    oom_handler(size, align)
}

// --- the global allocator ---------------------------------------------------

/// The program's global allocator: the kairo_global_* symbols
/// (rt/global_alloc.h), which the runtime defines weakly as System and the
/// file that writes @set_global_allocator(A) defines strongly as A. Chosen
/// when the program links, so no file has to know which one it gets. A
/// freestanding target defines the symbols itself, or uses the *_in family
/// with an allocator of its own.
///
/// Without LTO the symbols cost a call and System's alignment test per
/// allocation, so they are used only when some file in the program sets an
/// allocator: the driver then defines __KAIRO_GLOBAL_ALLOCATOR_SET for every
/// file it compiles. Otherwise Global is System itself, inlined into every
/// caller.
eval if !defined!(__KAIRO_GLOBAL_ALLOCATOR_SET) {
    pub type Global = System
} else {
    pub class Global impl FullAllocator {
        static inline fn alloc(size: usize, align: usize) -> unsafe *u8 {
            return kairo_global_alloc(size, align)
        }
        static inline fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
            return kairo_global_alloc_zeroed(size, align)
        }
        static inline fn free(ptr: unsafe *u8, size: usize, align: usize) {
            kairo_global_free(ptr, size, align)
        }
        static inline fn resize(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> bool {
            return kairo_global_resize(ptr, old_size, new_size, align)
        }
        static inline fn realloc(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 {
            return kairo_global_realloc(ptr, old_size, new_size, align)
        }
    }
}

// --- scoped allocation: runtime dispatch ------------------------------------
// A function cannot be emitted once per caller's allocator, so the active
// scoped allocator is runtime state: a per-thread stack of frames. Allocation
// goes to the top frame; freeing goes to the frame whose range holds the
// address, so a block from the global heap freed inside a scope still goes
// back to the global heap.
//
// The frames live in per-thread chunks of SCOPE_CHUNK: the first is in
// thread-local storage (rt/alloc.h), the rest are allocated the first time a thread nests
// that deep and kept for reuse. Each frame also carries the bounding box of
// every range open at or below it, so a free of a block that no open scope
// owns -- the common case inside deeply nested libraries -- is decided by the
// top frame alone at any depth. Only a block from a scope below the top is
// looked up, by a scan of each chunk's packed range arrays.

/// Frames per chunk.
eval SCOPE_CHUNK: usize = 16

/// Bytes rt/alloc.h reserves per thread for the first chunk
/// (KAIRO_RT_SCOPE_FIRST_BYTES there; keep the two equal).
eval SCOPE_FIRST_BYTES: usize = 1536

/// One active scope: the allocator's static functions as pointers, the range
/// snapshot taken when it opened, and the bounding box of it and every scope
/// below it. 64 bytes on a 64-bit target: one cache line.
pub struct ScopeFrame {
    var alloc:   unsafe fn(usize, usize) -> unsafe *u8
    var free:    unsafe fn(unsafe *u8, usize, usize)
    var resize:  unsafe fn(unsafe *u8, usize, usize, usize) -> bool
    var realloc: unsafe fn(unsafe *u8, usize, usize, usize) -> unsafe *u8
    var lo:      unsafe *u8
    var hi:      unsafe *u8
    var agg_lo:  unsafe *u8
    var agg_hi:  unsafe *u8
}

/// SCOPE_CHUNK frames, plus their ranges packed for the scan: lo[i + 1] and
/// span[i + 1] = hi - lo for frames[i], so a hit is one subtract and one
/// unsigned compare. Slot 0 is a sentinel (lo 0, span MAX) that every address
/// hits, which ends the scan of a chunk without a bounds check.
pub struct ScopeChunk {
    var frames: [ScopeFrame; 16]
    var lo:     [usize; 17]
    var span:   [usize; 17]
    var base:   usize                 // depth of frames[0]
    var prev:   unsafe *ScopeChunk
    var next:   unsafe *ScopeChunk
}

// Hosted targets have threads, so the stack is per thread. A target with no OS
// has no thread-local storage and, in practice, one thread.
eval if defined!(__linux__) || defined!(_WIN32) || defined!(__APPLE__)
     || defined!(__FreeBSD__) || defined!(__NetBSD__) || defined!(__OpenBSD__)
     || defined!(__ANDROID__) || defined!(__wasi__) || defined!(__EMSCRIPTEN__) {
    thread scope_top:   unsafe *ScopeFrame = &null
    thread scope_depth: usize = 0
    thread scope_chunk: unsafe *ScopeChunk = &null
} else {
    static scope_top:   unsafe *ScopeFrame = &null
    static scope_depth: usize = 0
    static scope_chunk: unsafe *ScopeChunk = &null
}

/// The next chunk after c, allocated the first time this thread nests this
/// deep. Kept after the scopes close, so nesting there again costs nothing.
@cold_path @no_inline
fn scope_grow(c: unsafe *ScopeChunk) -> unsafe *ScopeChunk {
    unsafe {
        var unsafe *n = c->next
        if n == &null {
            var unsafe *m = System::alloc(sizeof ScopeChunk, alignof ScopeChunk)
            @unlikely if m == &null { oom(sizeof ScopeChunk, alignof ScopeChunk) }
            n = m as unsafe *ScopeChunk
            n->base = c->base + SCOPE_CHUNK
            n->lo[0] = 0
            n->span[0] = ~0usize
            n->prev = c
            n->next = &null
            c->next = n
        }
        return n
    }
}

/// The open scope below the top whose range holds ptr, or &null: a scan of
/// the packed ranges, newest first, one subtract and one compare per frame.
@cold_path @no_inline
fn owner_scan(ptr: unsafe *u8) -> unsafe *ScopeFrame {
    // One cursor over lo[]: span[k] sits a fixed distance after lo[k], and the
    // frame index is computed only on a hit.
    var a: usize = 0
    var unsafe *c = scope_chunk
    var n: usize = 0
    unsafe {
        a = ptr as usize
        n = scope_depth - c->base
        while true {
            var unsafe *lo0 = &c->lo[0] as unsafe *usize
            var unsafe *q = lo0 + n
            while a - *q >= *(q + 17) { q = q - 1 }
            var k = ((q as usize) - (lo0 as usize)) / sizeof usize
            if k != 0 { return unsafe &c->frames[k - 1] }
            c = c->prev
            if c == &null { return &null }
            n = SCOPE_CHUNK
        }
    }
}

/// The innermost open scope whose range holds ptr; &null means the global
/// heap. The top frame answers both common cases: its own block, and a block
/// outside every open range.
inline fn owner_of(ptr: unsafe *u8) -> unsafe *ScopeFrame {
    var unsafe *f = scope_top
    if f == &null { return &null }
    unsafe {
        if ptr >= f->lo && ptr < f->hi { return f }
        if ptr < f->agg_lo || ptr >= f->agg_hi { return &null }
    }
    return owner_scan(ptr)
}

/// True when [lo, hi) overlaps no open scope's range, except the same
/// allocator nested in itself (same range, same free): a block there goes to
/// the innermost frame, which frees it through the same allocator.
@cold_path @no_inline
fn range_is_free(lo: unsafe *u8, hi: unsafe *u8, free: unsafe fn(unsafe *u8, usize, usize)) -> bool {
    var unsafe *c = scope_chunk
    var n: usize = 0
    unsafe { n = scope_depth - c->base }
    while c != &null {
        unsafe {
            while n > 0 {
                n -= 1
                var unsafe *f = unsafe &c->frames[n]
                var same = f->lo == lo && f->hi == hi && f->free == free
                if !same && lo < f->hi && f->lo < hi { return false }
            }
            c = c->prev
        }
        n = SCOPE_CHUNK
    }
    return true
}

/// Pushes a frame; returns its depth, which scope_pop takes back.
/// prot: AllocatorScope (base/alloc.k) is its one caller outside this file.
prot inline fn scope_push(alloc: unsafe fn(usize, usize) -> unsafe *u8,
              free: unsafe fn(unsafe *u8, usize, usize),
              resize: unsafe fn(unsafe *u8, usize, usize, usize) -> bool,
              realloc: unsafe fn(unsafe *u8, usize, usize, usize) -> unsafe *u8,
              lo: unsafe *u8, hi: unsafe *u8) -> usize {
    var d = scope_depth
    var unsafe *top = scope_top
    var unsafe *c = scope_chunk
    var i: usize = 0
    var unsafe *agg_lo = lo
    var unsafe *agg_hi = hi
    unsafe {
        if top == &null {
            // The first chunk's storage is in rt/alloc.h (see there for why).
            assert sizeof ScopeChunk <= SCOPE_FIRST_BYTES   // ScopeChunk outgrew its first-chunk storage
            c = kairo_rt_scope_first() as unsafe *ScopeChunk
            scope_chunk = c
            c->lo[0] = 0
            c->span[0] = ~0usize
        } else {
            // O(1) when the new range lies outside everything open; the scan
            // only runs when it falls inside the bounding box.
            if lo < top->agg_hi && top->agg_lo < hi {
                assert range_is_free(lo, hi, free)   // a scoped allocator's range overlaps an open scope's
            }
            if top->agg_lo < agg_lo { agg_lo = top->agg_lo }
            if top->agg_hi > agg_hi { agg_hi = top->agg_hi }
            i = d - c->base
            @unlikely if i == SCOPE_CHUNK {
                c = scope_grow(c)
                scope_chunk = c
                i = 0
            }
        }
        var unsafe *f = unsafe &c->frames[i]
        f->alloc = alloc
        f->free = free
        f->resize = resize
        f->realloc = realloc
        f->lo = lo
        f->hi = hi
        f->agg_lo = agg_lo
        f->agg_hi = agg_hi
        c->lo[i + 1] = lo as usize
        c->span[i + 1] = (hi as usize) - (lo as usize)
        scope_top = f
    }
    scope_depth = d + 1
    return d
}

/// Pops the frame scope_push returned d for. Scopes close in reverse order.
prot inline fn scope_pop(d: usize) {
    assert scope_depth == d + 1   // allocator scopes must close in reverse order
    scope_depth = d
    if d == 0 { scope_top = &null; return }
    unsafe {
        var unsafe *c = scope_chunk
        var i = d - c->base
        if i == 0 {
            c = c->prev
            scope_chunk = c
            i = SCOPE_CHUNK
        }
        scope_top = unsafe &c->frames[i - 1]
    }
}

// --- the current-allocator family -------------------------------------------

/// size bytes from the allocator in effect. &null on failure.
pub inline fn alloc_raw(size: usize, align: usize) -> unsafe *u8 {
    assert is_pow2(align)   // alignment must be a power of two
    if size == 0 { return dangling(align) }
    var unsafe *f = scope_top
    @likely if f == &null { return Global::alloc(size, align) }
    unsafe { return f->alloc(size, align) }
}

/// Gives a block back to whichever allocator it came from. With no scope
/// open this is one TLS load, one test and a tail call to Global::free.
pub inline fn free_raw(ptr: unsafe *u8, size: usize, align: usize) {
    if size == 0 { return }
    @likely if scope_top == &null { Global::free(ptr, size, align); return }
    free_scoped(ptr, size, align)
}

/// free_raw's slow path: a scope is open, so find the block's owner.
@cold_path @no_inline
fn free_scoped(ptr: unsafe *u8, size: usize, align: usize) {
    var unsafe *f = scope_top
    unsafe {
        if ptr >= f->lo && ptr < f->hi { f->free(ptr, size, align); return }
        if ptr < f->agg_lo || ptr >= f->agg_hi { Global::free(ptr, size, align); return }
    }
    free_below(ptr, size, align)
}

/// free_scoped's slowest path: the block is inside the bounding box but not
/// the top frame's, so scan the frames below.
@cold_path @no_inline
fn free_below(ptr: unsafe *u8, size: usize, align: usize) {
    var unsafe *f = owner_scan(ptr)
    if f == &null { Global::free(ptr, size, align); return }
    unsafe { f->free(ptr, size, align) }
}

/// Resizes with the allocator the block came from. &null: nothing changed.
pub fn resize_raw(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 {
    if new_size == 0 { free_raw(ptr, old_size, align); return dangling(align) }
    if old_size == 0 { return alloc_raw(new_size, align) }
    var f: unsafe *ScopeFrame = &null
    if scope_top != &null { f = owner_of(ptr) }
    if f == &null {
        if Global::resize(ptr, old_size, new_size, align) { return ptr }
        return Global::realloc(ptr, old_size, new_size, align)
    }
    unsafe {
        if f->resize(ptr, old_size, new_size, align) { return ptr }
        return f->realloc(ptr, old_size, new_size, align)
    }
}

// --- System: the default global allocator -----------------------------------
// mimalloc (rt/mimalloc.c). On ELF and wasm targets it is also the C heap, so
// C, C++ and Kairo share one heap; see rt/mimalloc.c for Windows and Apple.
// Size and alignment are usually constants here, so the small-object paths
// below fold to one direct call each.

/// What every supported malloc guarantees: 8 on 32-bit, 16 on 64-bit.
eval MAX_ALIGN: usize = 2 * sizeof usize

/// mimalloc's small-object limit, 128 words (rt/alloc.h kairo_rt_small_max).
eval SMALL_MAX: usize = 128 * sizeof usize

pub class System impl FullAllocator {
    static inline fn alloc(size: usize, align: usize) -> unsafe *u8 {
        @likely if align <= MAX_ALIGN { return kairo_rt_malloc(size) }
        return kairo_rt_aligned_alloc(size, align)
    }

    static inline fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        @likely if align <= MAX_ALIGN { return kairo_rt_calloc(size) }
        return kairo_rt_aligned_calloc(size, align)
    }

    static inline fn free(ptr: unsafe *u8, size: usize, align: usize) {
        @likely if align <= MAX_ALIGN { kairo_rt_free(ptr, size); return }
        kairo_rt_aligned_free(ptr, size, align)
    }

    /// Never grows in place. A shrink keeps the block, except one from a
    /// large page into the small range: the small free that size would get
    /// cannot release a large-page block (rt/alloc.h), so that one moves.
    static inline fn resize(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> bool {
        if new_size > old_size { return false }
        return !(align <= MAX_ALIGN && new_size <= SMALL_MAX && old_size > SMALL_MAX)
    }

    static fn realloc(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 {
        @likely if align <= MAX_ALIGN { return kairo_rt_realloc(ptr, old_size, new_size) }
        return kairo_rt_aligned_realloc(ptr, new_size, align)
    }
}

/// --- The Kairo Project ---------------------- Lib/builtin/base/alloc.k --- ///
///
///   \brief The allocator model: the allocator interfaces, typed uninitialized
///          storage, the allocation front end, the OOM hook, and the default
///          global allocator (System).
///
///   \detail
///     Three layers, each knowing only about the one below it:
///       - an allocator hands out bytes (alloc / free) and never sees a type;
///       - Uninitialized<T> / UninitializedSlice<T> is storage typed as T that
///         is not yet a T: the only way to get a *T from it is to construct
///         into it;
///       - create / destroy (std::create / std::destroy) use the allocator in
///         effect; the *_in<.., A> family names A. @create / @destroy will
///         lower to these.
///     Contract every allocator can rely on (the front end guarantees it):
///       - align is a power of two, size is never 0;
///       - free receives the size and align the block was made with (or the
///         new_size of the last successful resize / realloc), never null;
///       - a failed resize / realloc leaves the original block untouched.
///     Contract every allocator must keep:
///       - failure is &null: no abort, no panic (OOM policy is the front end's);
///       - a global allocator is thread-safe;
///       - a scoped allocator hands out only addresses inside range(), and no
///         two open scopes have overlapping ranges.
///     Pairing (not yet checked by the compiler):
///       - create / try_create / create_slice / alloc_raw pair with destroy /
///         destroy_slice / free_raw: the block goes back to whichever open
///         scope's range holds it, else to Global;
///       - the *_in<.., A> family pairs only with *_in<.., A> for the same A.
///         A block from create_in<T, A> where A is neither Global nor an open
///         scope must never reach destroy / free_raw: it would go to Global.
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
// The string lang item, for the messages here; not the root (`import
// builtin::Nullable`, which `T?` does not need): that closed a cycle,
// module.k -> containers/vector.k -> alloc.k -> module.k, warning R001W on
// every compile once a builtin the root imports allocates.
import builtin::string::*;
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

/// p + n bytes.
inline fn byte_offset(p: unsafe *u8, n: usize) -> unsafe *u8 {
    return p + n
}

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

fn default_oom(size: usize, align: usize) -> ! {
    var msg = "kairo: out of memory"
    __builtin_crash(msg.as_ptr(), msg.length(), 134)
}

/// Replaces what create does when the allocator returns &null.
pub fn set_oom_handler(h: fn(usize, usize) -> !) { oom_handler = h }

/// Runs the handler. The handler is typed -> !, and the compiler emits
/// __builtin_unreachable after a call through a -> ! fn value.
pub fn oom(size: usize, align: usize) -> ! {
    oom_handler(size, align)
}

// --- typed uninitialized storage --------------------------------------------

/// Storage for one T that holds no T. Move-only. Turn it into an object with
/// construct, or give it back with release_in.
pub class <T> Uninitialized {
    priv var ptr: unsafe *u8

    /// Wraps raw bytes. The caller vouches for size and alignment.
    pub inline fn Uninitialized(self, ptr: unsafe *u8) { self.ptr = ptr }

    @move
    pub fn Uninitialized(self, other: Self) = default

    /// Builds a T in the storage. The only safe way to a *T.
    pub inline fn <...A> construct(self, ...args: A) -> *T {
        return __builtin_construct_at<T>(self.ptr, args...)
    }

    /// For a T whose bytes have all been written through as_bytes. Only for
    /// types that come into being when their bytes are written (trivially
    /// copyable and destructible).
    pub inline fn assume_init(self) -> *T
      requires __builtin_is_trivially_copyable<T>() && __builtin_is_trivially_destructible<T>() {
        unsafe { return __builtin_launder(self.ptr as unsafe *T as *T) }
    }

    pub inline fn as_bytes(const self) -> unsafe *u8 { return self.ptr }

    /// Reinterprets the storage for a U of the same or smaller size and
    /// alignment. Nothing lives in it either way.
    pub fn <U> retype(self) -> Uninitialized<U>
      requires sizeof U <= sizeof T && alignof U <= alignof T {
        return Uninitialized<U>(self.ptr)
    }
}

/// Runs the destructor and hands the storage back.
pub inline fn <T> uninitialized_from(p: *T) -> Uninitialized<T> {
    __builtin_destruct_at(p)
    unsafe { return Uninitialized<T>(p as unsafe *u8) }
}

/// Storage for cap Ts, of which [0, len) are live. Dropping it destroys only
/// the live prefix; the storage itself goes back via destroy_slice or
/// destroy_slice_in.
pub class <T> UninitializedSlice {
    priv var ptr: unsafe *u8
    priv var cap: usize
    priv var len: usize

    pub inline fn UninitializedSlice(self, ptr: unsafe *u8, cap: usize) {
        self.ptr = ptr
        self.cap = cap
        self.len = 0
    }

    /// Leaves other empty (&null, 0, 0) so its drop destroys nothing. A null
    /// ptr here only ever marks a moved-from source: failure is a null
    /// UninitializedSlice<T>?, never a slice holding &null.
    @move
    pub inline fn UninitializedSlice(self, other: Self) {
        self.ptr  = other.ptr
        self.cap  = other.cap
        self.len  = other.len
        other.ptr = &null
        other.cap = 0
        other.len = 0
    }

    pub inline fn size(const self) -> usize { return self.len }
    pub inline fn capacity(const self) -> usize { return self.cap }
    pub inline fn as_bytes(const self) -> unsafe *u8 { return self.ptr }

    pub inline fn <...A> push(self, ...args: A) {
        @unlikely if self.len == self.cap { __builtin_trap() }
        __builtin_construct_at<T>(byte_offset(self.ptr, self.len * sizeof T), args...)
        self.len += 1
    }

    /// Every slot is live: ownership of the cap Ts moves to the caller, who
    /// destroys them and frees capacity() * sizeof T bytes.
    pub inline fn finish(self) -> *T {
        if self.len != self.cap { __builtin_trap() }
        self.len = 0
        unsafe { return self.ptr as unsafe *T as *T }
    }

    /// Destroys the live prefix, last first. Idempotent.
    pub fn clear(self) {
        while self.len > 0 {
            self.len -= 1
            unsafe {
                __builtin_destruct_at(byte_offset(self.ptr, self.len * sizeof T) as unsafe *T as *T)
            }
        }
    }

    fn op delete(self) { self.clear() }
}

// --- the front end ----------------------------------------------------------
// Zero-size requests never reach an allocator.

pub inline fn <A impl Allocator> alloc_bytes(size: usize, align: usize) -> unsafe *u8 {
    assert is_pow2(align), "alignment must be a power of two"
    if size == 0 { return dangling(align) }
    return A::alloc(size, align)
}

pub inline fn <A impl Allocator> free_bytes(ptr: unsafe *u8, size: usize, align: usize) {
    if size == 0 { return }
    A::free(ptr, size, align)
}

pub inline fn <A impl FullAllocator> alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
    assert is_pow2(align), "alignment must be a power of two"
    if size == 0 { return dangling(align) }
    return A::alloc_zeroed(size, align)
}

/// In place if the allocator can, else move. &null: nothing changed.
pub inline fn <A impl FullAllocator> resize_bytes(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 {
    if new_size == 0 { free_bytes<A>(ptr, old_size, align); return dangling(align) }
    if old_size == 0 { return alloc_bytes<A>(new_size, align) }
    if A::resize(ptr, old_size, new_size, align) { return ptr }
    return A::realloc(ptr, old_size, new_size, align)
}

/// Grows only without moving. For containers holding objects that are not
/// trivially relocatable.
pub inline fn <A impl FullAllocator> try_resize_in_place(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> bool {
    if old_size == 0 || new_size == 0 { return false }
    return A::resize(ptr, old_size, new_size, align)
}

/// Storage for one T, or null.
pub inline fn <T, A impl Allocator> alloc_in() -> Uninitialized<T>? {
    var unsafe *p = alloc_bytes<A>(sizeof T, alignof T)
    if p == &null { return null }
    return Uninitialized<T>(p)
}

/// Storage for n Ts, or null (including when n * sizeof T overflows).
pub inline fn <T, A impl Allocator> create_slice_in(n: usize) -> UninitializedSlice<T>? {
    var bytes: usize = 0
    if __builtin_mul_overflow(n, sizeof T, &bytes) { return null }
    var unsafe *p = alloc_bytes<A>(bytes, alignof T)
    if p == &null { return null }
    return UninitializedSlice<T>(p, n)
}

pub inline fn <T, A impl Allocator> release_in(@move u: Uninitialized<T>) {
    free_bytes<A>(u.as_bytes(), sizeof T, alignof T)
}

/// Destroys what is live, then frees the storage.
pub inline fn <T, A impl Allocator> destroy_slice_in(@move s: UninitializedSlice<T>) {
    s.clear()
    free_bytes<A>(s.as_bytes(), s.capacity() * sizeof T, alignof T)
}

/// T(args...) from A. Constructors never panic, so construction cannot fail
/// once the storage exists.
pub inline fn <T, A impl Allocator, ...Args> create_in(...args: Args) -> *T {
    var unsafe *p = alloc_bytes<A>(sizeof T, alignof T)
    @unlikely if p == &null { oom(sizeof T, alignof T) }
    return Uninitialized<T>(p).construct(args...)
}

/// T(args...) from A, or null instead of the OOM hook.
pub inline fn <T, A impl Allocator, ...Args> try_create_in(...args: Args) -> *T? {
    var unsafe *p = alloc_bytes<A>(sizeof T, alignof T)
    if p == &null { return null }
    return Uninitialized<T>(p).construct(args...)
}

/// Destruct, then free to A, as one step.
pub inline fn <T, A impl Allocator> destroy_in(p: *T) {
    // The dynamic type's size and alignment, read before the destructor
    // runs: a *Base holding a Derived frees sizeof Derived.
    var size  = __builtin_dynamic_size<T>(p)
    var align = __builtin_dynamic_align<T>(p)
    var u = uninitialized_from(p)
    free_bytes<A>(u.as_bytes(), size, align)
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
inline fn scope_push(alloc: unsafe fn(usize, usize) -> unsafe *u8,
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
            assert sizeof ScopeChunk <= SCOPE_FIRST_BYTES, "ScopeChunk outgrew its first-chunk storage"
            c = kairo_rt_scope_first() as unsafe *ScopeChunk
            scope_chunk = c
            c->lo[0] = 0
            c->span[0] = ~0usize
        } else {
            // O(1) when the new range lies outside everything open; the scan
            // only runs when it falls inside the bounding box.
            if lo < top->agg_hi && top->agg_lo < hi {
                assert range_is_free(lo, hi, free), "a scoped allocator's range overlaps an open scope's"
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
inline fn scope_pop(d: usize) {
    assert scope_depth == d + 1, "allocator scopes must close in reverse order"
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

/// Opens a scoped allocator for the rest of the enclosing block: every
/// allocation through the non-_in family, in this function and everything it
/// calls on this thread, comes from A until the guard is destroyed. Movable:
/// the frame lives in the thread's scope stack, not in the guard.
pub class <A impl ScopedFullAllocator> AllocatorScope {
    priv var mark:   usize
    priv var depth:  usize
    priv var active: bool

    pub inline fn AllocatorScope(self) {
        self.mark = A::enter()
        var r = A::range()
        self.depth = scope_push(A::alloc, A::free, A::resize, A::realloc, r.0, r.1)
        self.active = true
    }

    /// Move-only (a @move constructor makes the class non-copyable). The
    /// scope stays open; other no longer closes it.
    @move
    pub fn AllocatorScope(self, other: Self) {
        self.mark = other.mark
        self.depth = other.depth
        self.active = other.active
        other.active = false
    }

    /// Idempotent. Scopes close in reverse order of opening.
    fn op delete(self) {
        if !self.active { return }
        self.active = false
        scope_pop(self.depth)
        A::leave(self.mark)
    }
}

// --- the current-allocator family -------------------------------------------

/// size bytes from the allocator in effect. &null on failure.
pub inline fn alloc_raw(size: usize, align: usize) -> unsafe *u8 {
    assert is_pow2(align), "alignment must be a power of two"
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

/// A T from the allocator in effect. Runs the OOM hook on failure.
pub inline fn <T, ...Args> create(...args: Args) -> *T {
    var unsafe *p = alloc_raw(sizeof T, alignof T)
    @unlikely if p == &null { oom(sizeof T, alignof T) }
    return Uninitialized<T>(p).construct(args...)
}

/// A T from the allocator in effect, or null.
pub inline fn <T, ...Args> try_create(...args: Args) -> *T? {
    var unsafe *p = alloc_raw(sizeof T, alignof T)
    if p == &null { return null }
    return Uninitialized<T>(p).construct(args...)
}

/// Destroys *p and gives its storage back to the allocator it came from.
pub inline fn <T> destroy(p: *T) {
    var size  = __builtin_dynamic_size<T>(p)
    var align = __builtin_dynamic_align<T>(p)
    var u = uninitialized_from(p)
    free_raw(u.as_bytes(), size, align)
}

/// Storage for n Ts from the allocator in effect, or null.
pub inline fn <T> create_slice(n: usize) -> UninitializedSlice<T>? {
    var bytes: usize = 0
    if __builtin_mul_overflow(n, sizeof T, &bytes) { return null }
    var unsafe *p = alloc_raw(bytes, alignof T)
    if p == &null { return null }
    return UninitializedSlice<T>(p, n)
}

/// Destroys what is live and gives the storage back to its allocator.
pub inline fn <T> destroy_slice(@move s: UninitializedSlice<T>) {
    s.clear()
    free_raw(s.as_bytes(), s.capacity() * sizeof T, alignof T)
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

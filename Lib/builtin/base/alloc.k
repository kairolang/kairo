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
///       - @create / @destroy are mem::create / mem::destroy with the
///         allocator in effect (@A) filled in by the compiler.
///     Contract every allocator can rely on (the front end guarantees it):
///       - align is a power of two, size is never 0;
///       - free receives the size and align the block was made with (or the
///         new_size of the last successful resize / realloc), never null;
///       - a failed resize / realloc leaves the original block untouched.
///     Contract every allocator must keep:
///       - failure is &null: no abort, no panic (OOM policy is the front end's);
///       - a global allocator is thread-safe.
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
import builtin::Nullable;   // circular with module.k; allowed, warns R001W
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

/// Used with AllocatorScope (and later @mem::set_scoped_allocator). enter()
/// returns a token that leave() takes back (a u64 for now: a witness cast of
/// a `-> usize` static is emitted as `decltype(*)(sizeof(0))()`, which clang
/// rejects, so this is `usize` once that is fixed); range() is the address range
/// every block it hands out lies in while the scope is open.
pub interface ScopedAllocator derives Allocator {
    static fn enter() -> u64
    static fn leave(mark: u64)
    static fn range() -> (unsafe *u8, unsafe *u8)
}

/// What the front end and @mem::set_allocator take, until eval if can test a
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

/// p + n bytes. Goes through usize until the compiler has '+' on raw pointers;
/// replace the body with `return p + n` then.
inline fn byte_offset(p: unsafe *u8, n: usize) -> unsafe *u8 {
    unsafe { return ((p as usize) + n) as unsafe *u8 }
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

/// The handler is typed -> !, but a function pointer cannot carry that into
/// C++, and a handler that returns anyway must not fall through.
pub fn oom(size: usize, align: usize) -> ! {
    oom_handler(size, align)
    __builtin_abort()
}

// --- typed uninitialized storage --------------------------------------------

/// Storage for one T that holds no T. Move-only. Turn it into an object with
/// construct, or give it back with mem::release.
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
/// the live prefix; the storage itself goes back via release_slice.
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
        if __builtin_expect(self.len == self.cap, false) { __builtin_trap() }
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
    // alloc_bytes<A> is spelled out: <A> written inside a generic body is
    // dropped when nothing in the arguments deduces it.
    if new_size == 0 {
        if old_size != 0 { A::free(ptr, old_size, align) }
        return dangling(align)
    }
    if old_size == 0 { return A::alloc(new_size, align) }
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
    if sizeof T == 0 { return Uninitialized<T>(dangling(alignof T)) }
    var unsafe *p = A::alloc(sizeof T, alignof T)
    if p == &null { return null }
    return Uninitialized<T>(p)
}

/// Storage for n Ts, or null (including when n * sizeof T overflows).
pub inline fn <T, A impl Allocator> create_slice_in(n: usize) -> UninitializedSlice<T>? {
    var bytes: usize = 0
    if __builtin_mul_overflow(n, sizeof T, &bytes) { return null }
    if bytes == 0 { return UninitializedSlice<T>(dangling(alignof T), n) }
    var unsafe *p = A::alloc(bytes, alignof T)
    if p == &null { return null }
    return UninitializedSlice<T>(p, n)
}

pub inline fn <T, A impl Allocator> release_in(@move u: Uninitialized<T>) {
    if sizeof T == 0 { return }
    A::free(u.as_bytes(), sizeof T, alignof T)
}

/// Destroys what is live, then frees the storage.
pub inline fn <T, A impl Allocator> destroy_slice_in(@move s: UninitializedSlice<T>) {
    s.clear()
    var bytes = s.capacity() * sizeof T
    if bytes == 0 { return }
    A::free(s.as_bytes(), bytes, alignof T)
}

/// T(args...) from A. Constructors never panic, so construction cannot fail
/// once the storage exists.
pub inline fn <T, A impl Allocator, ...Args> create_in(...args: Args) -> *T {
    var unsafe *p = dangling(alignof T)
    if sizeof T != 0 { p = A::alloc(sizeof T, alignof T) }
    if __builtin_expect(p == &null, false) { oom(sizeof T, alignof T) }
    return Uninitialized<T>(p).construct(args...)
}

/// T(args...) from A, or null instead of the OOM hook.
pub inline fn <T, A impl Allocator, ...Args> try_create_in(...args: Args) -> *T? {
    var unsafe *p = dangling(alignof T)
    if sizeof T != 0 { p = A::alloc(sizeof T, alignof T) }
    if p == &null { return null }
    return Uninitialized<T>(p).construct(args...)
}

/// Destruct, then free to A, as one step.
pub inline fn <T, A impl Allocator> destroy_in(p: *T) {
    var u = uninitialized_from(p)
    if sizeof T == 0 { return }
    A::free(u.as_bytes(), sizeof T, alignof T)
}

// --- the global allocator ---------------------------------------------------

/// The program's global allocator. Fixed until @mem::set_allocator exists. A
/// freestanding target links its own malloc / free / realloc / calloc /
/// posix_memalign, or uses the *_in family with an allocator of its own.
pub type Global = System

// --- scoped allocation: runtime dispatch ------------------------------------
// A function cannot be emitted once per caller's allocator, so the active
// scoped allocator is runtime state: a per-thread stack of frames living on
// the stacks of the functions that opened them. Allocation goes to the top
// frame; freeing goes to the frame whose range holds the address, so a block
// from the global heap freed inside a scope still goes back to the global heap.

/// One active scope. Holds the allocator's static functions as pointers and
/// the range snapshot taken when it opened.
pub struct ScopeFrame {
    var alloc:   fn(usize, usize) -> unsafe *u8
    var free:    fn(unsafe *u8, usize, usize)
    var resize:  fn(unsafe *u8, usize, usize, usize) -> bool
    var realloc: fn(unsafe *u8, usize, usize, usize) -> unsafe *u8
    var lo:      unsafe *u8
    var hi:      unsafe *u8
    var prev:    unsafe *ScopeFrame
}

// Hosted targets have threads, so the stack is per thread. A target with no OS
// has no thread-local storage and, in practice, one thread.
eval if defined!(__linux__) || defined!(_WIN32) || defined!(__APPLE__)
     || defined!(__FreeBSD__) || defined!(__NetBSD__) || defined!(__OpenBSD__)
     || defined!(__ANDROID__) || defined!(__wasi__) || defined!(__EMSCRIPTEN__) {
    thread scope_top: unsafe *ScopeFrame = &null
} else {
    static scope_top: unsafe *ScopeFrame = &null
}

/// The innermost open scope whose range holds ptr; &null means the global heap.
inline fn owner_of(ptr: unsafe *u8) -> unsafe *ScopeFrame {
    // Through usize until the compiler has '<' on raw pointers, as byte_offset.
    var a = ptr as usize
    var unsafe *f = scope_top
    while f != &null {
        unsafe {
            if a >= (f->lo as usize) && a < (f->hi as usize) { return f }
            f = f->prev
        }
    }
    return &null
}

// The frame stores A's static functions as pointers; A::alloc written as a
// value inside a generic class is emitted against the interface, not the
// witness, so each goes through a trampoline.
fn <A impl ScopedFullAllocator> scope_alloc(size: usize, align: usize) -> unsafe *u8 { return A::alloc(size, align) }
fn <A impl ScopedFullAllocator> scope_free(ptr: unsafe *u8, size: usize, align: usize) { A::free(ptr, size, align) }
fn <A impl ScopedFullAllocator> scope_resize(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> bool { return A::resize(ptr, old_size, new_size, align) }
fn <A impl ScopedFullAllocator> scope_realloc(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 { return A::realloc(ptr, old_size, new_size, align) }

/// Opens a scoped allocator for the rest of the enclosing block: every
/// allocation through the non-_in family, in this function and everything it
/// calls on this thread, comes from A until the guard is destroyed. Pinned in
/// place, since the frame stack points into it.
pub class <A impl ScopedFullAllocator> AllocatorScope {
    priv var mark:   u64
    priv var active: bool
    priv var frame:  ScopeFrame

    pub fn AllocatorScope(self) {
        self.mark = A::enter()
        self.active = true
        var r = A::range()
        self.frame = ScopeFrame {
            alloc: scope_alloc<A>, free: scope_free<A>, resize: scope_resize<A>, realloc: scope_realloc<A>,
            lo: r.0, hi: r.1, prev: scope_top,
        }
        scope_top = unsafe &self.frame
    }

    @copy
    pub fn AllocatorScope(self, const other: Self) = delete
    @move
    pub fn AllocatorScope(self, other: Self) = delete

    /// Idempotent. Scopes close in reverse order of opening.
    fn op delete(self) {
        if !self.active { return }
        self.active = false
        assert scope_top == unsafe &self.frame, "allocator scopes must close in reverse order"
        scope_top = self.frame.prev
        A::leave(self.mark)
    }
}

// --- the current-allocator family -------------------------------------------

/// size bytes from the allocator in effect. &null on failure.
pub inline fn alloc_raw(size: usize, align: usize) -> unsafe *u8 {
    assert is_pow2(align), "alignment must be a power of two"
    if size == 0 { return dangling(align) }
    var unsafe *f = scope_top
    if __builtin_expect(f == &null, true) { return Global::alloc(size, align) }
    unsafe { return f->alloc(size, align) }
}

/// Gives a block back to whichever allocator it came from.
pub inline fn free_raw(ptr: unsafe *u8, size: usize, align: usize) {
    if size == 0 { return }
    var unsafe *f = owner_of(ptr)
    if f == &null { Global::free(ptr, size, align); return }
    unsafe { f->free(ptr, size, align) }
}

/// Resizes with the allocator the block came from. &null: nothing changed.
pub fn resize_raw(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 {
    if new_size == 0 { free_raw(ptr, old_size, align); return dangling(align) }
    if old_size == 0 { return alloc_raw(new_size, align) }
    var unsafe *f = owner_of(ptr)
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
    if __builtin_expect(p == &null, false) { oom(sizeof T, alignof T) }
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
    var u = uninitialized_from(p)
    free_raw(u.as_bytes(), sizeof T, alignof T)
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
// The platform's malloc, so memory that crosses into C++ and every sanitizer
// and heap profiler see the same heap.

/// What every supported malloc guarantees: 8 on 32-bit, 16 on 64-bit.
eval MAX_ALIGN: usize = 2 * sizeof usize

pub class System impl FullAllocator {
    static inline fn alloc(size: usize, align: usize) -> unsafe *u8 {
        if __builtin_expect(align <= MAX_ALIGN, true) { return kairo_rt_malloc(size) }
        return kairo_rt_aligned_alloc(size, align)
    }

    static inline fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        if __builtin_expect(align <= MAX_ALIGN, true) { return kairo_rt_calloc(size) }
        var unsafe *p = kairo_rt_aligned_alloc(size, align)
        if p != &null { __builtin_set_mem(p, 0u8 as byte, size) }
        return p
    }

    static inline fn free(ptr: unsafe *u8, size: usize, align: usize) {
        if __builtin_expect(align <= MAX_ALIGN, true) { kairo_rt_free(ptr, size); return }
        kairo_rt_aligned_free(ptr, size, align)
    }

    /// malloc cannot grow in place; a shrink keeps the block, and free
    /// ignores the size, so it is always valid.
    static inline fn resize(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> bool {
        return new_size <= old_size
    }

    static fn realloc(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 {
        if __builtin_expect(align <= MAX_ALIGN, true) { return kairo_rt_realloc(ptr, new_size) }
        return realloc_by_copy<System>(ptr, old_size, new_size, align)
    }
}
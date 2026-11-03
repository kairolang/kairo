/// --- The Kairo Project ---------------------- Lib/builtin/base/alloc.k --- ///
///
///   \brief The allocator model: typed uninitialized storage, the allocation
///          front end and the AllocatorScope guard, over the byte layer in
///          alloc_raw.k (the allocator interfaces, the OOM hook, Global /
///          System, the scope stack and alloc_raw / free_raw / resize_raw),
///          which this file re-exports.
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
pub import builtin::alloc_raw::*;
ffi "c++" import "rt/alloc.h"

// --- helpers ----------------------------------------------------------------

/// p + n bytes.
inline fn byte_offset(p: unsafe *u8, n: usize) -> unsafe *u8 {
    return p + n
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

// --- scoped allocation: the guard -------------------------------------------
// Here, not beside the scope stack in alloc_raw.k: a generic class bounded
// by an interface must not reach a header that every program includes
// (alloc_raw.hh comes in with string.hh), because header emission does not
// declare the witness its member bodies call through (ticket candidate).

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

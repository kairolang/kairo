/// --- The Kairo Project --------------------- Lib/builtin/base/alloc.k --- ///
///
/// The allocator model: typed uninitialized storage, the allocation
/// front end and the AllocatorScope guard, over the byte layer in
/// alloc_raw.k (the allocator interfaces, the OOM hook, Global /
/// System, the scope stack and alloc_raw / free_raw / resize_raw),
/// which this file re-exports.
///
///   \detail
///     Three layers, each knowing only about the one below it:
///       - an allocator hands out bytes (alloc / free) and never sees a type;
///       - Uninitialized<T> / UninitializedSlice<T> is storage typed as T that
///         is not yet a T: the only way to get a *T from it is to construct
///         into it;
///       - create / destroy (std::create / std::destroy) use the allocator in
///         effect; the *_in<.., A> family names A. The allocation
///         attributes (`@create`, `@destroy`, `@alloc`, `@free`, ...) stand
///         for these: `@create T(args)` is `create<T>(args)`, and
///         `@create(in: A) T(args)` is `create_in<T, A>(args)`.
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "rt/alloc.h"

pub import builtin::alloc_raw::*
import builtin::base::intrinsics::*
// The string lang item, for the messages here; not the root (`import
// builtin::Null`, which `T?` does not need): that closed a cycle,
// module.k -> containers/vector.k -> alloc.k -> module.k, warning R001W on
// every compile once a builtin the root imports allocates.
import builtin::string::*

// --- helpers ----------------------------------------------------------------

/// p + n bytes.
inline fn byte_offset(p: unsafe *u8, n: usize) -> unsafe *u8 {
    return p + n
}

// --- typed uninitialized storage --------------------------------------------

/// Storage for one `T` that holds no `T`. Move-only.
///
/// Turn it into an object with `construct`, or give it back with `release_in`. This is the typed
/// layer between an allocator's bytes and a live object.
pub class <T> Uninitialized {
    priv var ptr: unsafe *u8

    /// Wraps raw bytes. The caller vouches for size and alignment.
    pub inline fn Uninitialized(self, ptr: unsafe *u8) {
        self.ptr = ptr
    }

    /// Move constructor: takes over other's storage.
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
        unsafe {
            return __builtin_launder(self.ptr as unsafe *T as *T)
        }
    }

    /// Returns the storage as raw bytes.
    pub inline fn as_bytes(const self) -> unsafe *u8 {
        return self.ptr
    }

    /// Reinterprets the storage for a U of the same or smaller size and
    /// alignment. Nothing lives in it either way.
    pub fn <U> retype(self) -> Uninitialized<U>
      requires sizeof U <= sizeof T && alignof U <= alignof T {
        return Uninitialized<U>(self.ptr)
    }
}

/// Runs `*p`'s destructor and returns its storage as an `Uninitialized<T>`.
///
/// \safety `p` must point at a live `T` that is not used afterwards.
pub inline fn <T> uninitialized_from(p: *T) -> Uninitialized<T> {
    __builtin_destruct_at(p)
    unsafe {
        return Uninitialized<T>(p as unsafe *u8)
    }
}

/// Storage for `cap` Ts, of which `[0, len)` are live.
///
/// Dropping it destroys only the live prefix; the storage itself goes back through `destroy_slice`
/// or `destroy_slice_in`. Move-only: a moved-from slice is left empty so its drop destroys nothing.
pub class <T> UninitializedSlice {
    priv var ptr: unsafe *u8
    priv var cap: usize
    priv var len: usize

    /// Wraps `cap` Ts' worth of raw bytes, with none of them live.
    ///
    /// \safety `ptr` must be valid for `cap * sizeof T` bytes at `alignof T`.
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

    /// Returns the number of live elements.
    pub inline fn size(const self) -> usize {
        return self.len
    }

    /// Returns the number of elements the storage has room for.
    pub inline fn capacity(const self) -> usize {
        return self.cap
    }

    /// Returns the storage as raw bytes.
    pub inline fn as_bytes(const self) -> unsafe *u8 {
        return self.ptr
    }

    /// Constructs a `T` from `args` in the next free slot.
    ///
    /// \panics Traps (`__builtin_trap`) when the slice is full.
    pub inline fn <...A> push(self, ...args: A) {
        @unlikely
        if self.len == self.cap {
            __builtin_trap()
        }

        __builtin_construct_at<T>(
            byte_offset(self.ptr, self.len * sizeof T),
            args...,
        )

        self.len += 1
    }

    /// Every slot is live: ownership of the cap Ts moves to the caller, who
    /// destroys them and frees capacity() * sizeof T bytes.
    pub inline fn finish(self) -> *T {
        if self.len != self.cap {
            __builtin_trap()
        }

        self.len = 0
        unsafe {
            return self.ptr as unsafe *T as *T
        }
    }

    /// Destroys the live prefix, last first. Idempotent.
    pub fn clear(self) {
        while self.len > 0 {
            self.len -= 1
            unsafe {
                __builtin_destruct_at(
                    byte_offset(self.ptr, self.len * sizeof T) as unsafe *T as *T,
                )
            }
        }
    }

    fn op finally(self) {
        self.clear()
    }
}

// --- the front end ----------------------------------------------------------
// Zero-size requests never reach an allocator.

/// Allocates `size` bytes from allocator `A`. Returns `&null` on failure; a zero `size` returns
/// `dangling(align)` without calling `A`.
///
/// ### Parameters
/// - `align`: A power of two (asserted).
pub inline fn <A impl Allocator> alloc_bytes(size: usize, align: usize) -> unsafe *u8 {
    assert is_pow2(align), "alignment must be a power of two"
    if size == 0 {
        return dangling(align)
    }

    return A::alloc(size, align)
}

/// Frees a block to allocator `A`; a zero `size` is a no-op.
///
/// \safety `ptr` must be a block `A` returned for this `size` and `align`.
pub inline fn <A impl Allocator> free_bytes(ptr: unsafe *u8, size: usize, align: usize) {
    if size == 0 {
        return
    }

    A::free(ptr, size, align)
}

/// Allocates `size` zeroed bytes from allocator `A`. Returns `&null` on failure.
///
/// ### Parameters
/// - `align`: A power of two (asserted).
pub inline fn <A impl FullAllocator> alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
    assert is_pow2(align), "alignment must be a power of two"
    if size == 0 {
        return dangling(align)
    }

    return A::alloc_zeroed(size, align)
}

/// In place if the allocator can, else move. &null: nothing changed.
pub inline fn <A impl FullAllocator> resize_bytes(ptr:      unsafe *u8,
                                                  old_size: usize,
                                                  new_size: usize,
                                                  align:    usize) -> unsafe *u8 {
    if new_size == 0 {
        free_bytes<A>(ptr, old_size, align)
        return dangling(align)
    }

    if old_size == 0 {
        return alloc_bytes<A>(new_size, align)
    }

    if A::resize(ptr, old_size, new_size, align) {
        return ptr
    }

    return A::realloc(ptr, old_size, new_size, align)
}

/// Grows only without moving. For containers holding objects that are not
/// trivially relocatable.
pub inline fn <A impl FullAllocator> try_resize_in_place(ptr:      unsafe *u8,
                                                         old_size: usize,
                                                         new_size: usize,
                                                         align:    usize) -> bool {
    if old_size == 0 || new_size == 0 {
        return false
    }

    return A::resize(ptr, old_size, new_size, align)
}

/// Storage for one T, or null.
pub inline fn <T, A impl Allocator> alloc_in() -> Uninitialized<T>? {
    var unsafe *p = alloc_bytes<A>(sizeof T, alignof T)
    if p == &null {
        return null
    }

    return Uninitialized<T>(p)
}

/// Storage for n Ts, or null (including when n * sizeof T overflows).
pub inline fn <T, A impl Allocator> create_slice_in(n: usize) -> UninitializedSlice<T>? {
    var bytes: usize = 0
    if __builtin_mul_overflow(n, sizeof T, &bytes) {
        return null
    }

    var unsafe *p = alloc_bytes<A>(bytes, alignof T)
    if p == &null {
        return null
    }

    return UninitializedSlice<T>(p, n)
}

/// Gives the storage of an `Uninitialized<T>` back to allocator `A`.
///
/// \safety The storage must have come from `A`.
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
    @unlikely
    if p == &null {
        oom(sizeof T, alignof T)
    }

    return Uninitialized<T>(p).construct(args...)
}

/// T(args...) from A, or null instead of the OOM hook.
pub inline fn <T, A impl Allocator, ...Args> try_create_in(...args: Args) -> *T? {
    var unsafe *p = alloc_bytes<A>(sizeof T, alignof T)
    if p == &null {
        return null
    }

    return Uninitialized<T>(p).construct(args...)
}

/// Destruct, then free to A, as one step.
pub inline fn <T, A impl Allocator> destroy_in(p: *T) {
    // The dynamic type's size and alignment, read before the destructor
    // runs: a *Base holding a Derived frees sizeof Derived.
    var size  = __builtin_dynamic_size<T>(p)
    var align = __builtin_dynamic_align<T>(p)
    var u     = uninitialized_from(p)
    free_bytes<A>(u.as_bytes(), size, align)
}

/// A T from the allocator in effect. Runs the OOM hook on failure.
pub inline fn <T, ...Args> create(...args: Args) -> *T {
    var unsafe *p = alloc_raw(sizeof T, alignof T)
    @unlikely
    if p == &null {
        oom(sizeof T, alignof T)
    }

    return Uninitialized<T>(p).construct(args...)
}

/// A T from the allocator in effect, or null.
pub inline fn <T, ...Args> try_create(...args: Args) -> *T? {
    var unsafe *p = alloc_raw(sizeof T, alignof T)
    if p == &null {
        return null
    }

    return Uninitialized<T>(p).construct(args...)
}

/// Destroys *p and gives its storage back to the allocator it came from.
pub inline fn <T> destroy(p: *T) {
    var size  = __builtin_dynamic_size<T>(p)
    var align = __builtin_dynamic_align<T>(p)
    var u     = uninitialized_from(p)
    free_raw(u.as_bytes(), size, align)
}

/// Storage for n Ts from the allocator in effect, or null.
pub inline fn <T> create_slice(n: usize) -> UninitializedSlice<T>? {
    var bytes: usize = 0
    if __builtin_mul_overflow(n, sizeof T, &bytes) {
        return null
    }

    var unsafe *p = alloc_raw(bytes, alignof T)
    if p == &null {
        return null
    }

    return UninitializedSlice<T>(p, n)
}

/// Destroys what is live and gives the storage back to its allocator.
pub inline fn <T> destroy_slice(@move s: UninitializedSlice<T>) {
    s.clear()
    free_raw(s.as_bytes(), s.capacity() * sizeof T, alignof T)
}

// --- what the allocation attributes add --------------------------------------
// Each attribute (`@create`, `@alloc`, `@free`, ...) stands for one function
// of this file; `in: A` selects the form that names its allocator. The
// functions below are the forms the front end above did not have: typed
// storage and zeroed / in-place bytes from the allocator in effect, and the
// forms of destroy and free that name A and deduce T from the pointer.

/// Storage for one T from the allocator in effect, or null. `@alloc T`.
pub inline fn <T> alloc_storage() -> Uninitialized<T>? {
    var unsafe *p = alloc_raw(sizeof T, alignof T)
    if p == &null {
        return null
    }

    return Uninitialized<T>(p)
}

/// Gives the block `p` points at back to the allocator it came from without
/// running a destructor. `@free p`.
///
/// \safety `*p` is not used afterwards, and whatever it owned is leaked unless it was destroyed
/// (`p->finally()`) or moved out first.
pub inline fn <T> free_storage(p: *T) {
    var size  = __builtin_dynamic_size<T>(p)
    var align = __builtin_dynamic_align<T>(p)
    unsafe {
        free_raw(p as unsafe *u8, size, align)
    }
}

/// Gives the storage of an `Uninitialized<T>` back to the allocator it came from. `@free u`.
pub inline fn <T> free_storage(@move u: Uninitialized<T>) {
    free_raw(u.as_bytes(), sizeof T, alignof T)
}

/// Destroys what is live in the slice and gives its storage back to the allocator it came from.
/// `@free s`.
pub inline fn <T> free_storage(@move s: UninitializedSlice<T>) {
    s.clear()
    free_raw(s.as_bytes(), s.capacity() * sizeof T, alignof T)
}

/// `free_storage(p)` to allocator `A`. `@free(in: A) p`.
///
/// \safety The block must have come from `A`; `*p` is not used afterwards.
pub inline fn <A impl Allocator, T> free_storage_with(p: *T) {
    var size  = __builtin_dynamic_size<T>(p)
    var align = __builtin_dynamic_align<T>(p)
    unsafe {
        free_bytes<A>(p as unsafe *u8, size, align)
    }
}

/// `free_storage(u)` to allocator `A`. `@free(in: A) u`.
///
/// \safety The storage must have come from `A`.
pub inline fn <A impl Allocator, T> free_storage_with(@move u: Uninitialized<T>) {
    free_bytes<A>(u.as_bytes(), sizeof T, alignof T)
}

/// `free_storage(s)` to allocator `A`. `@free(in: A) s`.
///
/// \safety The storage must have come from `A`.
pub inline fn <A impl Allocator, T> free_storage_with(@move s: UninitializedSlice<T>) {
    s.clear()
    free_bytes<A>(s.as_bytes(), s.capacity() * sizeof T, alignof T)
}

/// `destroy_in<T, A>(p)` with T taken from the pointer. `@destroy(in: A) p`.
///
/// \safety The block must have come from `A`.
pub inline fn <A impl Allocator, T> destroy_with(p: *T) {
    var size  = __builtin_dynamic_size<T>(p)
    var align = __builtin_dynamic_align<T>(p)
    var u     = uninitialized_from(p)
    free_bytes<A>(u.as_bytes(), size, align)
}

/// `size` zeroed bytes from the allocator in effect. Returns `&null` on failure; a zero `size`
/// returns `dangling(align)`. `@alloc_zeroed(size: n, align: a)`.
///
/// ### Parameters
/// - `align`: A power of two (asserted).
pub inline fn alloc_raw_zeroed(size: usize, align: usize) -> unsafe *u8 {
    assert is_pow2(align), "alignment must be a power of two"
    if size == 0 {
        return dangling(align)
    }

    return alloc_zeroed_raw(size, align)
}

/// Resizes a block in place with the allocator it came from; false, with the block untouched,
/// when that allocator cannot, or when either size is zero.
/// `@try_resize(size: o, new_size: n, align: a) p`.
///
/// \safety `ptr` must come from `alloc_raw` / `resize_raw` with `old_size` and `align`.
pub inline fn resize_raw_in_place(ptr:      unsafe *u8,
                                  old_size: usize,
                                  new_size: usize,
                                  align:    usize) -> bool {
    if old_size == 0 || new_size == 0 {
        return false
    }

    return try_resize_raw(ptr, old_size, new_size, align)
}

// --- scoped allocation: the guard -------------------------------------------
// Here, not beside the scope stack in alloc_raw.k: a generic class bounded
// by an interface must not reach a header that every program includes
// (alloc_raw.hh comes in with string.hh), because header emission does not
// declare the witness its member bodies call through (ticket candidate).

/// Opens a scoped allocator for the rest of the enclosing block: every allocation through the
/// non-`_in` family (`create`, `alloc_raw`, containers), in this function and everything it calls
/// on this thread, comes from `A` until the guard is destroyed.
///
/// Movable: the frame lives in the thread's scope stack, not in the guard. Scopes must close in
/// reverse order of opening, and a block freed inside a scope goes back to whichever allocator's
/// range holds it, so a global-heap block freed inside a scope still reaches the global heap.
pub class <A impl ScopedFullAllocator> AllocatorScope {
    priv var mark:   usize
    priv var depth:  usize
    priv var active: bool

    /// Opens the scope: calls `A::enter()` and pushes a frame holding `A`'s functions and range.
    ///
    /// \panics Crashes when `A::range()` overlaps the range of an open scope.
    pub inline fn AllocatorScope(self) {
        self.mark = A::enter()
        var r = A::range()
        self.depth = scope_push(
            A::alloc,
            A::free,
            A::resize,
            A::realloc,
            r.0,
            r.1,
        )

        self.active = true
    }

    /// Move-only (a @move constructor makes the class non-copyable). The
    /// scope stays open; other no longer closes it.
    @move
    pub fn AllocatorScope(self, other: Self) {
        self.mark    = other.mark
        self.depth   = other.depth
        self.active  = other.active
        other.active = false
    }

    /// Idempotent. Scopes close in reverse order of opening.
    fn op finally(self) {
        if !self.active {
            return
        }

        self.active = false
        scope_pop(self.depth)
        A::leave(self.mark)
    }
}

// --- scoped allocation: one arena per object ---------------------------------
// `@set_scoped_allocator(A)` on a class or struct gives each object an arena
// of its own. The attribute adds two fields, an ObjectArena<A> first and an
// ObjectArenaEnd<A> last, and starts every method with an ObjectArenaScope<A>
// over the first. Fields are built in declaration order and destroyed in
// reverse, so the two bracket everything that happens to the fields between
// them:
//
//   construction   ObjectArena opens the arena; ObjectArenaEnd adopts it.
//   destruction    ObjectArenaEnd opens a scope over the arena, the other
//                  fields free into it, ObjectArena closes the scope and
//                  frees the arena.
//   assignment     member by member, first field first: ObjectArena opens
//                  the scope over the old arena, the other fields free their
//                  old blocks into it, ObjectArenaEnd closes the scope and
//                  frees the old arena; each takes the new handle.
//
// What one of the pair begins the other finishes, through a per-thread stack
// of pending steps. The fields of an object nested between the two push and
// pop their own steps in balance, so the top step is always the pair's own.

/// A scoped allocator that keeps one arena per owner: what `@set_scoped_allocator(A)` on a class
/// or struct takes.
///
/// `alloc` serves the arena `arena_enter` made current; `free`, `resize` and `realloc` find the
/// arena from the block's address. The ranges of two live arenas never overlap.
pub interface ArenaAllocator derives FullAllocator {
    /// Makes a new, empty arena and returns its handle, which is never 0.
    static fn arena_open() -> usize
    /// Frees every block of the arena, and the arena.
    static fn arena_close(arena: usize)
    /// Makes `arena` the one `alloc` serves. Returns the handle it replaces, 0 when none was
    /// current.
    static fn arena_enter(arena: usize) -> usize
    /// Makes `previous`, a handle `arena_enter` returned, current again.
    static fn arena_leave(previous: usize)
    /// Returns the half-open address range `[lo, hi)` every block of `arena` lies in. It is fixed
    /// for the arena's life.
    static fn arena_range(arena: usize) -> (unsafe *u8, unsafe *u8)
}

/// How deep objects with an arena may nest inside one another while one is built, destroyed or
/// assigned.
eval ARENA_PENDING_MAX: usize = 64

/// Words per pending step: the allocator's tag, the arena's handle, what `arena_enter` returned,
/// and the scope's depth.
eval ARENA_PENDING_WORDS: usize = 4

eval if defined!(__linux__) || defined!(_WIN32) || defined!(__APPLE__)
     || defined!(__FreeBSD__) || defined!(__NetBSD__) || defined!(__OpenBSD__)
     || defined!(__ANDROID__) || defined!(__wasi__) || defined!(__EMSCRIPTEN__) {
    thread arena_pending:   [usize; 256]
    thread arena_pending_n: usize        = 0
} else {
    static arena_pending:   [usize; 256]
    static arena_pending_n: usize        = 0
}

/// A number that tells allocator type `A` from every other: two allocators may hand out equal
/// handles.
fn <A impl ArenaAllocator> arena_tag() -> usize {
    static mark: u8 = 0
    unsafe {
        return (&mark as unsafe *u8) as usize
    }
}

/// Pushes a pending step.
fn arena_pending_push(tag: usize, arena: usize, prev: usize, depth: usize) {
    var n = arena_pending_n
    @unlikely
    if n == ARENA_PENDING_MAX {
        __builtin_trap()
    }

    arena_pending[n * ARENA_PENDING_WORDS]     = tag
    arena_pending[n * ARENA_PENDING_WORDS + 1] = arena
    arena_pending[n * ARENA_PENDING_WORDS + 2] = prev
    arena_pending[n * ARENA_PENDING_WORDS + 3] = depth
    arena_pending_n                            = n + 1
}

/// True when the top pending step is the one for `arena` of the allocator `tag`.
fn arena_pending_is(tag: usize, arena: usize) -> bool {
    var n = arena_pending_n
    return n > 0
        && arena_pending[(n - 1) * ARENA_PENDING_WORDS] == tag
        && arena_pending[(n - 1) * ARENA_PENDING_WORDS + 1] == arena
}

/// Opens a scope over `arena` and leaves a pending step for the other field of the pair.
fn <A impl ArenaAllocator> arena_begin(arena: usize) {
    var prev  = A::arena_enter(arena)
    var r     = A::arena_range(arena)
    var depth = scope_push(A::alloc, A::free, A::resize, A::realloc, r.0, r.1)

    arena_pending_push(arena_tag<A>(), arena, prev, depth)
}

/// Finishes the top pending step, which is `arena`'s: closes its scope and frees the arena.
fn <A impl ArenaAllocator> arena_finish(arena: usize) {
    var n     = arena_pending_n - 1
    var prev  = arena_pending[n * ARENA_PENDING_WORDS + 2]
    var depth = arena_pending[n * ARENA_PENDING_WORDS + 3]
    arena_pending_n = n
    scope_pop(depth)
    A::arena_leave(prev)
    A::arena_close(arena)
}

/// Begins or finishes the end of an arena's life with one owner: whichever of the owner's two
/// fields is destroyed first begins, and the other finishes.
fn <A impl ArenaAllocator> arena_release(arena: usize) {
    if arena == 0 {
        return
    }

    if arena_pending_is(arena_tag<A>(), arena) {
        arena_finish<A>(arena)
        return
    }

    arena_begin<A>(arena)
}

/// The arena one object owns: the first field `@set_scoped_allocator(A)` adds to a class or
/// struct. Its constructor opens the arena.
///
/// Move-only: moving the owner moves its arena, and a moved-from ObjectArena owns nothing.
pub class <A impl ArenaAllocator> ObjectArena {
    priv var arena: usize

    /// Opens a new arena, and leaves its handle for the owner's ObjectArenaEnd.
    pub inline fn ObjectArena(self) {
        self.arena = A::arena_open()
        arena_pending_push(arena_tag<A>(), self.arena, 0, 0)
    }

    /// Takes over other's arena; other owns nothing afterwards.
    @move
    pub inline fn ObjectArena(self, other: Self) {
        self.arena  = other.arena
        other.arena = 0
    }

    /// Returns the arena's handle, 0 when this owns none.
    pub inline fn handle(const self) -> usize {
        return self.arena
    }

    /// Frees this arena and takes over other's: what a hand-written move constructor of the owner
    /// starts with, so the blocks it moves across stay with their arena.
    pub fn take(self, other: *ObjectArena<A>) {
        if self.arena != 0 {
            A::arena_close(self.arena)
        }

        self.arena   = other->arena
        other->arena = 0
    }

    fn op finally(self) {
        arena_release<A>(self.arena)
        self.arena = 0
    }
}

/// The last field `@set_scoped_allocator(A)` adds to a class or struct: it holds the same handle
/// as the owner's ObjectArena, and is destroyed before every other field.
pub class <A impl ArenaAllocator> ObjectArenaEnd {
    priv var arena: usize

    /// Adopts the arena the owner's ObjectArena opened.
    pub inline fn ObjectArenaEnd(self) {
        var n = arena_pending_n - 1
        self.arena      = arena_pending[n * ARENA_PENDING_WORDS + 1]
        arena_pending_n = n
    }

    /// Takes over other's handle; other holds none afterwards.
    @move
    pub inline fn ObjectArenaEnd(self, other: Self) {
        self.arena  = other.arena
        other.arena = 0
    }

    /// Takes over other's handle after the owner's ObjectArena took the arena: the second
    /// statement of a hand-written move constructor of the owner.
    pub fn take(self, other: *ObjectArenaEnd<A>) {
        self.arena   = other->arena
        other->arena = 0
    }

    fn op finally(self) {
        arena_release<A>(self.arena)
        self.arena = 0
    }
}

/// Opens an object's arena for the rest of the enclosing block: what every method of a
/// `@set_scoped_allocator(A)` class or struct starts with.
///
/// Allocations through the non-`_in` family, in the method and everything it calls on this thread,
/// come from the object's arena until the guard is destroyed. A guard over an ObjectArena that
/// owns nothing opens no scope.
pub class <A impl ArenaAllocator> ObjectArenaScope {
    priv var prev:   usize
    priv var depth:  usize
    priv var active: bool

    /// Opens the scope: makes the arena current and pushes a frame holding `A`'s functions and
    /// the arena's range.
    pub inline fn ObjectArenaScope(self, arena: *const ObjectArena<A>) {
        var h = arena->handle()
        self.prev   = 0
        self.depth  = 0
        self.active = false
        if h == 0 {
            return
        }

        self.prev = A::arena_enter(h)
        var r = A::arena_range(h)
        self.depth = scope_push(
            A::alloc,
            A::free,
            A::resize,
            A::realloc,
            r.0,
            r.1,
        )

        self.active = true
    }

    /// Move-only. The scope stays open; other no longer closes it.
    @move
    pub fn ObjectArenaScope(self, other: Self) {
        self.prev    = other.prev
        self.depth   = other.depth
        self.active  = other.active
        other.active = false
    }

    /// Idempotent. Scopes close in reverse order of opening.
    fn op finally(self) {
        if !self.active {
            return
        }

        self.active = false
        scope_pop(self.depth)
        A::arena_leave(self.prev)
    }
}

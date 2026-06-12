/// This file contains the ideas for the kairo standerd library. It is not part of the standard library, nor is it final, just a place to put ideas for the standard library. It is not guaranteed to be stable, and may change at any time.

// the std is split into 4 layers
// kairo::
// core::
// std::
// ...:: // this is the layer where things like crypo, math, and other things that are not part of the standard library but are useful for kairo programs will go

//===----------------------------------------------------------------------===//
//===----------------------------------------------------------------------===//
//===----------------------------------------------------------------------===//
//===----------------------------------------------------------------------===//
//===----------------------------------------------------------------------===//
//===----------------------------------------------------------------------===//
//===----------------------------------------------------------------------===//
//===----------------------------------------------------------------------===//
//===----------------------------------------------------------------------===//

eval if defined!(__unix__) {
    enum SIGNAL {
        SIGHUP  = 1,  SIGINT    = 2,  SIGQUIT = 3,  SIGILL    = 4,
        SIGTRAP = 5,  SIGABRT   = 6,  SIGBUS  = 7,  SIGFPE    = 8,
        SIGKILL = 9,  SIGUSR1   = 10, SIGSEGV = 11, SIGUSR2   = 12,
        SIGPIPE = 13, SIGALRM   = 14, SIGTERM = 15, SIGSTKFLT = 16,
        SIGCHLD = 17, SIGCONT   = 18, SIGSTOP = 19, SIGTSTP   = 20,
        SIGTTIN = 21, SIGTTOU   = 22, SIGURG  = 23, SIGXCPU   = 24,
        SIGXFSZ = 25, SIGVTALRM = 26, SIGPROF = 27, SIGWINCH  = 28,
        SIGIO   = 29, SIGPWR    = 30, SIGSYS  = 31,
    }
} else {
    enum SIGNAL {
        SIGINT  = 2,
        SIGILL  = 4,
        SIGABRT = 6,
        SIGFPE  = 8,
        SIGSEGV = 11,
        SIGTERM = 15,
    }
}

fn __builtin_alloc(size: usize) -> *void
fn __builtin_alloc_zero(size: usize) -> *void
fn __builtin_alloc_align(size: usize, alignment: usize) -> *void
fn __builtin_free(ptr: *void)
fn __builtin_realloc(ptr: *void, new_size: usize) -> *void
fn <T, ...U> __builtin_construct_at(ptr: *void, ...args: U)
fn <T> __builtin_destruct_at(ptr: *T)
fn <T> __builtin_size_of() -> usize
fn <T> __builtin_align_of() -> usize
fn __builtin_copy(dst: *void, src: *void, size: usize)
fn __builtin_move_mem(dst: *void, src: *void, size: usize)
fn __builtin_set_mem(ptr: *void, value: i32, size: usize)
fn __builtin_has_scoped_alloc() -> bool
fn <T> __builtin_is_trivial_destruct() -> bool
fn <T> __builtin_is_trivial_construct() -> bool
fn <T> __builtin_is_trivial_copy() -> bool
fn <N: usize> __builtin_crash(msg: const [char; N], exit_code: i32) -> !
fn <N: usize> __builtin_signal(msg: const [char; N], signal: SIGNAL) -> !
fn __builtin_max_align() -> usize
fn __builtin_global_allocator() -> *core::Allocator
fn __builtin_scoped_allocator() -> *core::ScopedAllocator

                     // avoids monomorphization of this function rather inlines
@kairo::InlineSource // it into the caller as source code not llvm ir
fn <T> op sizeof () -> usize {
    return __builtin_sizeof(T)
}

@kairo::InlineSource
fn <T> op alignof () -> usize {
    return __builtin_alignof(T)
}

module core {
    // core layer is the lowest layer of the standard library, it contains the most basic building blocks of the language, such as types, functions, and macros. It is the foundation upon which the other layers are built.
    interface Allocator {
        @kairo::Crashes
        fn alloc(self, size: usize, align: usize) -> *void
        fn try_alloc(self, size: usize, align: usize) -> *void?
        @kairo::Crashes
        fn realloc(self, ptr: *void, old_size: usize, new_size: usize, align: usize) -> bool
        fn try_realloc(self, ptr: *void, old_size: usize, new_size: usize, align: usize) -> bool
        fn free(self, ptr: *void, size: usize)
    }

    interface ScopedAllocator derives Allocator {
        fn op delete (self) // should free all the memory allocated by this allocator
    }

    class LibcAllocator impl Allocator, ScopedAllocator /* we satisfy both interfaces */ {
        fn alloc(self, size: usize, align: usize) -> *void {
            var ptr: *void = if align <= __builtin_max_align() {
                __builtin_alloc(size)
            } else {
                __builtin_alloc_align(size, align)
            }
            if ptr == &null {
                __builtin_crash("LibcAllocator: out of memory", 1)
            }
            return ptr
        }

        fn try_alloc(self, size: usize, align: usize) -> *void? {
            return if align <= __builtin_max_align() {
                __builtin_alloc(size)
            } else {
                __builtin_alloc_align(size, align)
            }
        }

        fn realloc(self, ptr: *void, old_size: usize, new_size: usize, align: usize) -> bool {
            if align > __builtin_max_align() {
                // aligned realloc: alloc new, copy, free old caller handles via try_realloc
                // crashing variant assumes in-place; if we can't guarantee it, abort
                __builtin_crash("LibcAllocator: aligned realloc cannot guarantee in-place", 1)
            }
            var new_ptr: *void = __builtin_realloc(ptr, new_size)
            if new_ptr == &null {
                __builtin_crash("LibcAllocator: out of memory during realloc", 1)
            }
            return new_ptr == ptr
        }

        fn try_realloc(self, ptr: *void, old_size: usize, new_size: usize, align: usize) -> bool {
            if align > __builtin_max_align() {
                return false
            }
            var new_ptr: *void = __builtin_realloc(ptr, new_size)
            if new_ptr == &null {
                return false
            }
            return new_ptr == ptr
        }

        fn free(self, ptr: *void, size: usize) {
            __builtin_free(ptr)
        }

        fn op delete (self) {
            // no-op for LibcAllocator, as it does not manage any state
            // This is just to satisfy the ScopedAllocator interface, which requires a delete operation
        }
    }
}

module std {
    @kairo::InlineSource
    fn <T, ...U> create(...args: U) -> *T {
        eval if __builtin_has_scoped_alloc() {
            var mem = __builtin_scoped_allocator().alloc(
                __builtin_size_of<T>(),
                __builtin_align_of<T>()
            )
            __builtin_construct_at<T>(mem, ...args)
            return mem as *T
        } else {
            var mem = __builtin_global_allocator().alloc(
                __builtin_size_of<T>(),
                __builtin_align_of<T>()
            )
            __builtin_construct_at<T>(mem, ...args)
            return mem as *T
        }
    }

    @kairo::InlineSource
    fn <T, ...U> try_create(...args: U) -> *T? {
        eval if __builtin_has_scoped_alloc() {
            var mem = __builtin_scoped_allocator().try_alloc(
                __builtin_size_of<T>(),
                __builtin_align_of<T>()
            )
            if !mem? { return null }
            __builtin_construct_at<T>(mem, ...args)
            return mem as *T
        } else {
            var mem = __builtin_global_allocator().try_alloc(
                __builtin_size_of<T>(),
                __builtin_align_of<T>()
            )
            if !mem? { return null }
            __builtin_construct_at<T>(mem, ...args)
            return mem as *T
        }
    }

    @kairo::InlineSource
    fn <T> destroy(obj: *T) {
        __builtin_destruct_at<T>(obj)
        eval if __builtin_has_scoped_alloc() {
            __builtin_scoped_allocator().free(obj as *void, __builtin_size_of<T>())
        } else {
            __builtin_global_allocator().free(obj as *void, __builtin_size_of<T>())
        }
    }

    @kairo::InlineSource
    fn <T> alloc(count: usize) -> *T {
        eval if __builtin_has_scoped_alloc() {
            return __builtin_scoped_allocator().alloc(
                count * __builtin_size_of<T>(),
                __builtin_align_of<T>()
            ) as *T
        } else {
            return __builtin_global_allocator().alloc(
                count * __builtin_size_of<T>(),
                __builtin_align_of<T>()
            ) as *T
        }
    }

    @kairo::InlineSource
    fn <T> try_alloc(count: usize) -> *T? {
        eval if __builtin_has_scoped_alloc() {
            var mem = __builtin_scoped_allocator().try_alloc(
                count * __builtin_size_of<T>(),
                __builtin_align_of<T>()
            )
            if !mem? { return null }
            return mem as *T
        } else {
            var mem = __builtin_global_allocator().try_alloc(
                count * __builtin_size_of<T>(),
                __builtin_align_of<T>()
            )
            if !mem? { return null }
            return mem as *T
        }
    }
}


module std {
    ///
    ///   Storage strategy for `Nullable<T>` (the desugaring of `T?`). Three
    ///   specializations selected by `requires`:
    ///     * safe-pointer T  -> niche-filled, null == 0x0, no tag, sizeof(T).
    ///     * niche-capable T  -> niche-filled in a spare bit pattern (e.g. bool).
    ///     * everything else  -> tagged { value; present } fallback.
    ///
    ///   This type exposes ONLY primitives. The surface operators `?`, `?.`, `??`,
    ///   and the `unwrap!()` macro are sema desugarings (see lang spec) that call
    ///   these primitives. `__value()` does NOT null-check; callers (the desugars)
    ///   gate it with `is_null()` or a narrowing proof.
    ///

    eval fn <T> is_safe_pointer_t()                          -> bool = false
    eval fn     is_safe_pointer_t<*T>()                      -> bool = true
    eval fn     is_safe_pointer_t<const *T>()                -> bool = true
    eval fn     is_safe_pointer_t<*const T>()                -> bool = true
    eval fn     is_safe_pointer_t<volatile *T>()             -> bool = true
    eval fn     is_safe_pointer_t<const volatile *T>()       -> bool = true
    eval fn     is_safe_pointer_t<const *const T>()          -> bool = true
    eval fn     is_safe_pointer_t<const volatile *const T>() -> bool = true

    eval fn <T> is_unsafe_pointer_t()                                 -> bool = false
    eval fn     is_unsafe_pointer_t<unsafe *T>()                      -> bool = true
    eval fn     is_unsafe_pointer_t<unsafe const *T>()                -> bool = true
    eval fn     is_unsafe_pointer_t<unsafe *const T>()                -> bool = true
    eval fn     is_unsafe_pointer_t<unsafe volatile *T>()             -> bool = true
    eval fn     is_unsafe_pointer_t<unsafe const volatile *T>()       -> bool = true
    eval fn     is_unsafe_pointer_t<unsafe const *const T>()          -> bool = true
    eval fn     is_unsafe_pointer_t<unsafe const volatile *const T>() -> bool = true

    //  Default: tagged fallback. Unconstrained, matches any T with no niche.
    //  (A more-specialized specialization wins when its `requires` holds.)
    struct <T> NullableStorage {
        var value:   T
        var present: bool
    }
    
    //  NOTE: there is deliberately no @packed tagged specialization. Kairo follows
    //  C++ layout rules, so a non-@packed T already has sizeof(T) % alignof(T) == 0.
    //  For align-1 T, the tagged { value; present } is identical packed or not.
    //  For align>1 T, packing would save bytes only by misaligning `value` in
    //  aggregates, a hidden access cost we don't impose by default. A user who
    //  wants the packed layout expresses it with @packed at their own declaration.
    extend <T> NullableStorage {
        @copy
        inline fn NullableStorage(self, other: Self) {
            self.value = other.value; self.present = other.present
        }
        inline fn NullableStorage(self, value: T) { self.value = value; self.present = true }
        inline fn NullableStorage(self)            { self.value = T(); self.present = false }

        inline static fn null() -> NullableStorage<T> = NullableStorage()

        inline fn is_null(self) -> bool = !self.present

        /// UNCHECKED. Precondition: !is_null(). Sema-only call site.
        inline fn __value(self) -> T = self.value

        inline fn op == (self, other: Self) -> bool =
            self.present == other.present && ((!self.present) || self.value == other.value)
        inline fn op != (self, other: Self) -> bool = !(self == other)
    }

    //  Safe-pointer specialization: niche-filled. null == 0x0. No tag. sizeof(P).
    @kairo::__intrinsic_always_safe()   // suppress AMT on the raw-pointer slot; std-only
    struct <> NullableStorage<P>
      requires is_safe_pointer_t<P>() {
        priv var ptr: unsafe P       // holds P's bits raw; 0x0 == None
    }

    @kairo::__intrinsic_always_safe()
    extend <> NullableStorage<P>
      requires is_safe_pointer_t<P>() {
        @copy
        inline fn NullableStorage(self, other: Self) { self.ptr = other.ptr }
        inline fn NullableStorage(self, value: P)    { self.ptr = value as unsafe P }
        inline fn NullableStorage(self)              { self.ptr = 0x0 as unsafe P }

        inline static fn null() -> NullableStorage<P> = NullableStorage()

        inline fn is_null(self) -> bool = self.ptr == (0x0 as unsafe P)

        /// UNCHECKED. Precondition: !is_null(). Reinterprets the raw slot as the
        /// non-null P. Sema-only call site; the desugar/narrowing proves non-null.
        inline fn __value(self) -> P = self.ptr as P

        inline fn op == (self, other: Self) -> bool = self.ptr == other.ptr
        inline fn op != (self, other: Self) -> bool = self.ptr != other.ptr
    }

    //  bool specialization: niche in the spare bit patterns (bool uses 0/1).
    //  INVALID (0x02) is the None pattern. One byte, no tag.
    @kairo::__intrinsic_always_safe()
    struct <> NullableStorage<bool> {
        priv var byte: u8   // 0x00 == Some(false), 0x01 == Some(true), 0x02 == None
    }

    @kairo::__intrinsic_always_safe()
    extend <> NullableStorage<bool> {
        eval INVALID: u8 = 0x02

        @copy
        inline fn NullableStorage(self, other: Self) { self.byte = other.byte }
        inline fn NullableStorage(self, value: bool) { self.byte = value as u8 }   // 0/1
        inline fn NullableStorage(self)              { self.byte = INVALID }

        inline static fn null() -> NullableStorage<bool> = NullableStorage()

        inline fn is_null(self) -> bool = self.byte == INVALID

        /// UNCHECKED. Precondition: !is_null(). byte is 0 or 1 here.
        inline fn __value(self) -> bool = self.byte != 0x00

        inline fn op == (self, other: Self) -> bool = self.byte == other.byte
        inline fn op != (self, other: Self) -> bool = self.byte != other.byte
    }

    // the ONE user-facing type, methods live here, storage delegated.
    struct <T> Nullable {
        var storage: NullableStorage<T>

        fn is_null(self) -> bool  { return self.storage.is_null(); }
        fn unwrap(self) -> T      { /* panic if null, else return value */ }
        // map, unwrap_or, ?? lowering, etc.
    }
}

class Foo {
    var data: i32?

    fn Foo() = default

    fn change_data(self) {
        self.data = null
    }

    fn make_data(self) {
        self.data = 42
    }
}

var foo = Foo()
foo.make_data()
if foo.data? {
    std::println(f"Data is: {foo.data}")
    foo.change_data()
    std::println(f"Data is now: {foo.data}")
}
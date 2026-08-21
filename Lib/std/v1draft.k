/// This file contains the ideas for the kairo standerd library. It is not part of the standard library, nor is it final, just a place to put ideas for the standard library. It is not guaranteed to be stable, and may change at any time.

// the std is split into 4 layers
// kairo::
// core::
// std::
// ...:: // this is the layer where things like crypto, math, time, etc... and other things that are not part of the standard library but are useful for kairo programs will go

/*
The line between std core kairo and ... is clear:
core, this is the lowest layer of the standard library, it contains the most basic building blocks of the language, such as types, functions, and macros, basic allocators, and other things that are needed to build the other layers of the standard library. It is the foundation upon which the other layers are built.
std, this is the layer that contains the standard library, what can be std and not:
- if it is integral to the language, take `[u8]` that desuagrs to the known type of `std::Vec<u8>`, it has to be std, not collections::Vec.
- if it is useful for most programs, it has to be std.
the above must be satisfied to be a part of the std layer, take time, its useful for most programs, but it is not integral to the language, in the sense, that you can make a program without it, so it is not std.
something like mutex, it is useful for most programs, and it is integral to the language, in the sense that you cant make a program without it, so it is std. Yes a user can reimplemnt mutex, but it is not trivial to do so, since it lowers to the OS level. not langauge abstractions.

*/

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
fn <const N: usize> __builtin_crash(msg: const [char; N], exit_code: i32) -> !
fn <const N: usize> __builtin_signal(msg: const [char; N], signal: SIGNAL) -> !
fn __builtin_max_align() -> usize
fn __builtin_global_allocator() -> *core::Allocator
fn __builtin_scoped_allocator() -> *core::ScopedAllocator

module core {
    // core layer is the lowest layer of the standard library, it contains the most basic building blocks of the language, such as types, functions, and macros. It is the foundation upon which the other layers are built.
    virtual interface Allocator {
        @Crashes
        fn alloc(self, size: usize, align: usize) -> *void
        fn try_alloc(self, size: usize, align: usize) -> *void?
        @Crashes
        fn realloc(self, ptr: *void, old_size: usize, new_size: usize, align: usize) -> bool
        fn try_realloc(self, ptr: *void, old_size: usize, new_size: usize, align: usize) -> bool
        fn free(self, ptr: *void, size: usize)
    }

    virtual interface ScopedAllocator derives Allocator {
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
    @InlineSource
    fn <T, ...U> create(...args: U) -> *T {
        eval if __builtin_has_scoped_alloc() {
            var mem = __builtin_scoped_allocator().alloc(
                __builtin_size_of<T>(),
                __builtin_align_of<T>()
            )
            __builtin_construct_at<T>(mem, args...)
            return mem as *T
        } else {
            var mem = __builtin_global_allocator().alloc(
                __builtin_size_of<T>(),
                __builtin_align_of<T>()
            )
            __builtin_construct_at<T>(mem, args...)
            return mem as *T
        }
    }

    @InlineSource
    fn <T, ...U> try_create(...args: U) -> *T? {
        eval if __builtin_has_scoped_alloc() {
            var mem = __builtin_scoped_allocator().try_alloc(
                __builtin_size_of<T>(),
                __builtin_align_of<T>()
            )
            if !mem? { return null }
            __builtin_construct_at<T>(mem, args...)
            return mem as *T
        } else {
            var mem = __builtin_global_allocator().try_alloc(
                __builtin_size_of<T>(),
                __builtin_align_of<T>()
            )
            if !mem? { return null }
            __builtin_construct_at<T>(mem, args...)
            return mem as *T
        }
    }

    @InlineSource
    fn <T> destroy(obj: *T) {
        __builtin_destruct_at<T>(obj)
        eval if __builtin_has_scoped_alloc() {
            __builtin_scoped_allocator().free(obj as *void, __builtin_size_of<T>())
        } else {
            __builtin_global_allocator().free(obj as *void, __builtin_size_of<T>())
        }
    }

    @InlineSource
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

    @InlineSource
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


static thread_local __ALLOC_PTR: fn (usize, usize) -> *void
static thread_local __FREE_PTR: fn (*void, usize)
static thread_local __REALLOC_PTR: fn (*void, usize, usize) -> *void
static thread_local __ALIGNED_ALLOC_PTR: fn (usize, usize) -> *void
static thread_local __ALIGNED_FREE_PTR: fn (*void, usize)
static thread_local __IN_SCOPED_CONTEXT: bool = false;

/* scoped allcators in sepficic do something intresting whith this contxt tkae:

@set_scoped_allocator(ArenaAllocator)
fn work_with_arena() {
    var my_vec: [Foo];
    my_vec.reserve(100); // This will use the ArenaAllocator
}

now after the macro has been processed
fn work_with_arena() {
    var __ORIGINAL_ALLOC_PTR         = __ALLOC_PTR
    var __ORIGINAL_FREE_PTR          = __FREE_PTR
    var __ORIGINAL_REALLOC_PTR       = __REALLOC_PTR
    var __ORIGINAL_ALIGNED_ALLOC_PTR = __ALIGNED_ALLOC_PTR
    var __ORIGINAL_ALIGNED_FREE_PTR  = __ALIGNED_FREE_PTR
    var __ORIGINAL_IN_SCOPED_CONTEXT = __IN_SCOPED_CONTEXT
    var SCOPED_ALLOCATOR = ArenaAllocator(); // this can safely sit on the stack of this function since all callers are in the same scope
    __ALLOC_PTR         = SCOPED_ALLOCATOR.alloc
    __FREE_PTR          = SCOPED_ALLOCATOR.free
    __REALLOC_PTR       = SCOPED_ALLOCATOR.realloc;
    __ALIGNED_ALLOC_PTR = SCOPED_ALLOCATOR.aligned_alloc
    __ALIGNED_FREE_PTR  = SCOPED_ALLOCATOR.aligned_free
    __IN_SCOPED_CONTEXT = true

    var my_vec: [Foo];
    my_vec.reserve(100); // std::create will use the pointer anyways so this is fine

    // end of scope we release and resotre the original allocators
    __ALLOC_PTR         = __ORIGINAL_ALLOC_PTR
    __FREE_PTR          = __ORIGINAL_FREE_PTR
    __REALLOC_PTR       = __ORIGINAL_REALLOC_PTR
    __ALIGNED_ALLOC_PTR = __ORIGINAL_ALIGNED_ALLOC_PTR
    __ALIGNED_FREE_PTR  = __ORIGINAL_ALIGNED_FREE_PTR
    __IN_SCOPED_CONTEXT = __ORIGINAL_IN_SCOPED_CONTEXT
    delete SCOPED_ALLOCATOR // calls cleanup
}
*/


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

// using it like:
var x = std::create<Foo>(10);

// would anyways expand in first pass - source inlining

var x = fn <T, ...U> (...args: U) -> *T {
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
}<Foo>(10) // IIFE

// then further boil down to:
var x = __builtin_construct_at(
    LibcAllocator::alloc(__builtin_size_of<Foo>(), __builtin_align_of<Foo>()),
    10
) as *Foo
// finally resoliving the remaining builtins after type resolve and name resolve is done
// leaving somehting like:
var x = __builtin_construct_at( // this stays cuz then it becomes a clean placement allocation
    LibcAllocator::alloc(64, 8),
    10
) as *Foo



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
    struct <P> NullableStorage<P>
      requires is_safe_pointer_t<P>() {
        priv var ptr: unsafe P       // holds P's bits raw; 0x0 == None
    }

    @kairo::__intrinsic_always_safe()
    extend <P> NullableStorage<P>
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

    fn get_data(const self) -> i32 {
        if self.data? {
            return self.data;
        } else {
            return 0;
        }
    }
}

var foo = Foo()
foo.make_data()
if foo.data? {
    std::println(f"Data is: {foo.data}")
    foo.change_data() // we do a fast pass if change_data is not const, we error on auto deref agian
    std::println(f"Data is now: {foo.data}") // error: cannot use a nullable value without checking
}


static thread __ALLOC_PTR: fn (usize, usize) -> *void
static thread __FREE_PTR: fn (*void, usize)
static thread __REALLOC_PTR: fn (*void, usize, usize) -> *void
static thread __ALIGNED_ALLOC_PTR: fn (usize, usize) -> *void
static thread __ALIGNED_FREE_PTR: fn (*void, usize)
static thread __IN_SCOPED_CONTEXT: bool = false;

/* scoped allcators in sepficic do something intresting whith this contxt tkae: */

@set_scoped_allocator(ArenaAllocator)
fn work_with_arena() {
    var my_vec: [Foo];
    my_vec.reserve(100); // This will use the ArenaAllocator
}


fn work_with_arena() {
    var __ORIGINAL_ALLOC_PTR         = __ALLOC_PTR
    var __ORIGINAL_FREE_PTR          = __FREE_PTR
    var __ORIGINAL_REALLOC_PTR       = __REALLOC_PTR
    var __ORIGINAL_ALIGNED_ALLOC_PTR = __ALIGNED_ALLOC_PTR
    var __ORIGINAL_ALIGNED_FREE_PTR  = __ALIGNED_FREE_PTR
    var __ORIGINAL_IN_SCOPED_CONTEXT = __IN_SCOPED_CONTEXT
    var SCOPED_ALLOCATOR = ArenaAllocator(); // this can safely sit on the stack of this function since all callers are in the same scope
    __ALLOC_PTR         = SCOPED_ALLOCATOR.alloc
    __FREE_PTR          = SCOPED_ALLOCATOR.free
    __REALLOC_PTR       = SCOPED_ALLOCATOR.realloc;
    __ALIGNED_ALLOC_PTR = SCOPED_ALLOCATOR.aligned_alloc
    __ALIGNED_FREE_PTR  = SCOPED_ALLOCATOR.aligned_free
    __IN_SCOPED_CONTEXT = true

    var my_vec: [Foo];
    my_vec.reserve(100); // std::create will use the pointer anyways so this is fine

    // end of scope we release and resotre the original allocators
    __ALLOC_PTR         = __ORIGINAL_ALLOC_PTR
    __FREE_PTR          = __ORIGINAL_FREE_PTR
    __REALLOC_PTR       = __ORIGINAL_REALLOC_PTR
    __ALIGNED_ALLOC_PTR = __ORIGINAL_ALIGNED_ALLOC_PTR
    __ALIGNED_FREE_PTR  = __ORIGINAL_ALIGNED_FREE_PTR
    __IN_SCOPED_CONTEXT = __ORIGINAL_IN_SCOPED_CONTEXT
    delete SCOPED_ALLOCATOR // calls cleanup
}

@InlineSource
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

// using it like:
var x = std::create<Foo>(10);

// would anyways expand in first pass - source inlining

var x = fn <T, ...U> (...args: U) -> *T {
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
}<Foo>(10) // IIFE

// then further boil down to:
var x = __builtin_construct_at(
    LibcAllocator::alloc(__builtin_size_of<Foo>(), __builtin_align_of<Foo>()),
    10
) as *Foo
// finally resoliving the remaining builtins after type resolve and name resolve is done
// leaving somehting like:
var x = __builtin_construct_at( // this stays cuz then it becomes a clean placement allocation
    LibcAllocator::alloc(64, 8),
    10
) as *Foo
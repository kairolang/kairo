/**
 * Memory wise since this is the first thing we need to figure out before anything else
 *
 */

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
fn __builtin_set_mem(ptr: *void, value: byte, size: usize)
fn __builtin_has_scoped_alloc() -> bool
fn <T> __builtin_is_trivial_destruct() -> bool
fn <T> __builtin_is_trivial_construct() -> bool
fn <T> __builtin_is_trivial_copy() -> bool
fn <N: usize> __builtin_crash(msg: const [char; N], exit_code: i32) -> !
fn <N: usize> __builtin_signal(msg: const [char; N], signal: SIGNAL) -> !
fn __builtin_max_align() -> usize

/// full family of compiler inbuilt attributes
/// @create    - allocates and initializes
/// @destroy   - cleans up and deallocates
/// @free      - frees memory
/// @alloc     - allocates memory
/// @realloc   - reallocates memory
/// @construct - constructs an object at a given location
/// @destruct  - destroys an object at a given location
///
/// Macros:
/// memcpy!
/// memmove!
/// memset!

macro memcpy!(dst, src, size)   { __builtin_copy(dst, src, size);      }
macro memmove!(dst, src, size)  { __builtin_move_mem(dst, src, size);  }
macro memset!(ptr, value, size) { __builtin_set_mem(ptr, value, size); }

/// Usage:
/// ```kairo
/// @create T(args...)
/// @create i32(10)
/// ```
macro @create(node: *AST::CallExpression) {
    // this one needs to do something transformational
    // we will always have a call expression
    // we need to generate roughly:
    // @create i32(10) - Node wise is a CallExpression with a name: ChainExpr, and arguments: [LiteralExpr(10)]
    // it becomes:
    // __builtin_construct_at<name as Type>(__builtin_alloc(sizeof name as Type), args...)
    // Nodes to create:
    // 1. CallExpr(name: ChainExpr, arguments: [LiteralExpr(10)], generics: [name as Type])
    
    var node_name = AST::ToCode(node.name);
    var construct = AST::ParseCallExpr(f"__builtin_construct_at<{node_name}>(__builtin_alloc(sizeof {node_name}))");
    construct.arguments.append_all(node.arguments);
    AST::Transform(node, construct);
}

@create i32(10) // works now cleanly
@create [i32; 10] // doesn't work yet but should work soon

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
    eval fn <T> is_safe_pointer_t<*T>()                      -> bool = true
    eval fn <T> is_safe_pointer_t<const *T>()                -> bool = true
    eval fn <T> is_safe_pointer_t<*const T>()                -> bool = true
    eval fn <T> is_safe_pointer_t<volatile *T>()             -> bool = true
    eval fn <T> is_safe_pointer_t<const volatile *T>()       -> bool = true
    eval fn <T> is_safe_pointer_t<const *const T>()          -> bool = true
    eval fn <T> is_safe_pointer_t<const volatile *const T>() -> bool = true

    eval fn <T> is_unsafe_pointer_t()                                 -> bool = false
    eval fn <T> is_unsafe_pointer_t<unsafe *T>()                      -> bool = true
    eval fn <T> is_unsafe_pointer_t<unsafe const *T>()                -> bool = true
    eval fn <T> is_unsafe_pointer_t<unsafe *const T>()                -> bool = true
    eval fn <T> is_unsafe_pointer_t<unsafe volatile *T>()             -> bool = true
    eval fn <T> is_unsafe_pointer_t<unsafe const volatile *T>()       -> bool = true
    eval fn <T> is_unsafe_pointer_t<unsafe const *const T>()          -> bool = true
    eval fn <T> is_unsafe_pointer_t<unsafe const volatile *const T>() -> bool = true

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
    @__intrinsic_always_safe()   // suppress AMT on the raw-pointer slot; std-only
    struct <P> NullableStorage<P>
      requires is_safe_pointer_t<P>() {
        priv var ptr: unsafe P       // holds P's bits raw; 0x0 == None
    }

    @__intrinsic_always_safe()
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
    @__intrinsic_always_safe()
    struct <> NullableStorage<bool> {
        priv var byte: u8   // 0x00 == Some(false), 0x01 == Some(true), 0x02 == None
    }

    @__intrinsic_always_safe()
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
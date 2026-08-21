/// --- The Kairo Project ------------------------------------- std-draft.k --- ///
///
///   \brief Working draft of the Kairo standard library.
///
///   \detail
///     Not part of the standard library, not final, not expected to compile.
///     A place to settle shape and API before sema exists to check any of it.
///
///     Sections marked SETTLED are carried over from earlier drafts and are
///     believed correct. Sections marked OPEN carry a decision that has to be
///     made before the code below them means anything. Sections marked STUB
///     have a signature and a design note but no body.
///
/// ------------------------------------------------------------------------ ///

//===----------------------------------------------------------------------===//
//  LAYERING                                                          SETTLED
//===----------------------------------------------------------------------===//
//
//  Four layers. The line between them is a rule, not a vibe.
//
//    kairo::   the language's own namespace. Everything emitted lands here.
//    core::    lowest layer. Building blocks the rest of the library needs:
//              allocator interfaces, the raw memory ops, the primitive traits.
//              Has no dependencies of its own.
//    std::     the standard library proper. Two tests, both must pass:
//                1. integral to the language  — `[u8]` desugars to std::Vec<u8>,
//                   so Vec cannot live in collections::.
//                2. useful to most programs.
//              Mutex passes: useful to most programs, and not reimplementable
//              without dropping to the OS. Time fails: useful, but a program
//              can exist without it.
//    ...::     everything else. crypto, math, time, net. Useful, not integral.
//
//  Namespace mapping across the FFI boundary:
//    Kairo side:  std:: is Kairo's,  cxx:: is C++'s
//    C++ side:    std:: is C++'s,    kairo:: is Kairo's
//

//===----------------------------------------------------------------------===//
//  OPEN DECISION 1 — scoped allocator: lexical or dynamic?
//===----------------------------------------------------------------------===//
//
//  Everything in the memory layer below depends on this. It is the single
//  most expensive thing to get wrong.
//
//  LEXICAL (compile-time):
//    `__builtin_has_scoped_alloc()` is an eval query. `eval if` works, zero
//    runtime cost, no thread-locals. But only code textually inside the
//    annotated function is affected — `my_vec.reserve(100)` allocates inside
//    Vec::reserve, whose body is not in the annotated function, so it uses
//    the global allocator. The motivating example does not work.
//
//  DYNAMIC (runtime):
//    Thread-local allocator pointers, swapped on scope entry and restored on
//    exit. Callees inherit. The example works. Costs: a load-and-test in
//    every allocating function, and every @create compiles both paths.
//
//  Dynamic is what the model wants. Consequences to accept and write down:
//    - __builtin_has_scoped_alloc() is NOT eval. Uses below say `if`, not
//      `eval if`. Fix the older drafts.
//    - Save/restore must run on every exit edge including the panic edge.
//      Panic is a checked effect so this is an ordinary early return, but the
//      restore has to be on that path too.
//    - The emitted C++ operator new/operator delete for exported classes
//      deliberately BYPASS this indirection and address the global allocator
//      directly. See interop spec. Without that, a C++ `delete` running while
//      a Kairo arena is active hands a global allocation to the arena.
//
//  TODO: pick one, then sweep every `eval if __builtin_has_scoped_alloc()`
//        in this file.
//

//===----------------------------------------------------------------------===//
//  SIGNAL                                                            SETTLED
//===----------------------------------------------------------------------===//

eval if defined!(__unix__) {
    enum SIGNAL derives i32 {
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
    enum SIGNAL derives i32 {
        SIGINT  = 2,
        SIGILL  = 4,
        SIGABRT = 6,
        SIGFPE  = 8,
        SIGSEGV = 11,
        SIGTERM = 15,
    }
}

enum MemoryOrder derives u8 {
    Relaxed,
    Consume,
    Acquire,
    Release,
    AcqRel,
    SeqCst,
}

//===----------------------------------------------------------------------===//
//  INTRINSICS                                                        PARTIAL
//===----------------------------------------------------------------------===//
//
//  Every intrinsic has two implementations:
//    Stage 1 — lower to the matching Clang builtin. Free.
//    Stage 2 — self-hosted. Answer from Kairo's own record data, or emit the
//              LLVM intrinsic directly.
//
//  The ones marked OWN NOW have no Clang equivalent, so Stage 1 must
//  implement them itself. Those are the interesting ones.
//

//  -- memory: raw allocation ------------------------------------------------
//
//  NOTE  These return `unsafe *u8`, not `*void`. `*T` is the non-null safe
//        pointer; allocation returns memory that may be null and does not yet
//        hold a valid T. Both properties are wrong for `*T`. The safe pointer
//        appears only as the result of construct_at.
//
fn __builtin_alloc(size: usize) -> unsafe *u8?
fn __builtin_alloc_zero(size: usize) -> unsafe *u8?
fn __builtin_alloc_align(size: usize, align: usize) -> unsafe *u8?
fn __builtin_free(ptr: unsafe *u8)
fn __builtin_max_align() -> usize

//  NOTE  realloc returns the NEW pointer. The earlier draft returned a
//        moved/not-moved bool and discarded the pointer when the block moved,
//        which leaks the block and leaves the caller holding a dangling
//        pointer. If the moved bit is wanted it is a second out-param.
fn __builtin_realloc(ptr: unsafe *u8, old_size: usize, new_size: usize) -> unsafe *u8?

//  -- memory: raw operations ------------------------------------------------
//
//  MUST lower to LLVM intrinsics, not calls. The optimizer pattern-matches
//  these for vectorization and constant folding; a plain call kills arena and
//  container throughput.
//
fn __builtin_copy(dst: unsafe *u8, src: unsafe *u8, size: usize)
fn __builtin_move_mem(dst: unsafe *u8, src: unsafe *u8, size: usize)
fn __builtin_set_mem(ptr: unsafe *u8, value: byte, size: usize)   // byte, not i32
fn __builtin_compare_mem(a: unsafe *u8, b: unsafe *u8, size: usize) -> i32

fn <T, ...U> __builtin_construct_at(ptr: unsafe *u8, ...args: U) -> *T
fn <T> __builtin_destruct_at(ptr: *T)
fn <T> __builtin_bit_cast<From>(v: From) -> T
fn <T> __builtin_launder(ptr: *T) -> *T
fn __builtin_assume_aligned(ptr: unsafe *u8, align: usize) -> unsafe *u8
fn __builtin_alloca(size: usize) -> unsafe *u8
fn __builtin_alloca_align(size: usize, align: usize) -> unsafe *u8

//  -- memory: allocator hooks -----------------------------------------------
fn __builtin_has_scoped_alloc() -> bool          // see OPEN DECISION 1
fn __builtin_scoped_allocator() -> *core::ScopedAllocator
fn __builtin_global_allocator() -> *core::Allocator

//  -- layout ----------------------------------------------------------------
fn <T> __builtin_size_of() -> usize
fn <T> __builtin_align_of() -> usize
fn <T> __builtin_offset_of(field: FieldRef) -> usize
//        ^ needed for the Stage 1 layout verification pass: compare Kairo's
//          computed field offsets against Clang's, debug builds only. A silent
//          divergence there is a miscompile with no diagnostic.

//  -- traits: layout and declaration facts ----------------------------------
//
//  Not library-implementable at any cost. A trivial and a non-trivial copy
//  constructor are indistinguishable from any call site — same expression,
//  same result, different codegen contract. There is no probe.
//
eval fn <T>    __builtin_is_trivially_copyable() -> bool
eval fn <T>    __builtin_is_trivially_destructible() -> bool
eval fn <T, ...A> __builtin_is_trivially_constructible() -> bool
eval fn <T, U> __builtin_is_trivially_assignable() -> bool
eval fn <T>    __builtin_is_standard_layout() -> bool
eval fn <T>    __builtin_is_aggregate() -> bool
eval fn <T>    __builtin_is_empty() -> bool
eval fn <T>    __builtin_is_polymorphic() -> bool
eval fn <T>    __builtin_is_abstract() -> bool
eval fn <T>    __builtin_is_final() -> bool
eval fn <B, D> __builtin_is_base_of() -> bool
eval fn <E>    __builtin_underlying_type() -> Type
eval fn <T>    __builtin_has_virtual_destructor() -> bool
//
//  NOTE  is_base_of is NOT is_convertible<D*, B*>. The latter lies on private
//        and ambiguous bases. It needs the real inheritance graph including
//        inaccessible edges, which no expression can see.

//  -- traits: OWN NOW, no Clang equivalent ----------------------------------
//
//  This block is the reason the intrinsic list is worth writing. Everything
//  above delegates to Clang in Stage 1. These cannot, so Stage 1 owns them
//  regardless of the bootstrap story.
//
eval fn <T> __builtin_is_trivially_relocatable() -> bool
//        ^ memcpy-move-and-skip-destroy. The trait Vec actually wants. C++
//          still lacks it; LLVM's containers approximate it with heuristics.
//          Owning it is a real win over libc++, not parity.
//          TODO: define the rule. A type is trivially relocatable if it is
//                trivially move-constructible AND trivially destructible, OR
//                it is annotated @relocatable and the annotation is checked.
//                Decide whether self-referential types are excluded by
//                analysis or by annotation only.

eval fn <T> __builtin_is_safe_pointer() -> bool
eval fn <T> __builtin_is_unsafe_pointer() -> bool
//        ^ currently drafted as `eval fn` specializations, eight entries each,
//          growing with every qualifier combination. Compilers query pointer
//          predicates constantly and each specialization query instantiates a
//          template. Make them intrinsic before the list gets longer.
//          See the SETTLED specialization block below for what they replace.

eval fn <T> __builtin_is_nullable() -> bool         // T? detection
eval fn <F> __builtin_panic_set_of() -> EffectSet
//        ^ the inferred effect set of a callable. EffectPropagation needs it,
//          and so does any generic wrapper that must forward its callee's
//          effects rather than declaring its own.
eval fn <T> __builtin_is_tuple() -> bool
eval fn <T> __builtin_tuple_arity() -> usize
//        ^ tuples are compiler-generated structs. Sema knows the arity and
//          nothing else can.

//  -- traits: expression probes ---------------------------------------------
//
//  These ARE implementable with `requires` / expression SFINAE. Make them
//  intrinsic anyway: each SFINAE query instantiates several class templates,
//  and the cost is instantiation machinery rather than codegen, so no
//  optimization closes the gap. Layer `interface`s on top for the constraint
//  API — that is where Kairo beats C++, since a named constraint gives a real
//  error message instead of an overload-resolution puzzle.
//
//  The intrinsic is ground truth. The interface is the API. Do not make the
//  interface compute the ground truth.
//
eval fn <T, U>    __builtin_is_same() -> bool
eval fn <F, T>    __builtin_is_convertible() -> bool
eval fn <T, ...A> __builtin_is_constructible() -> bool
eval fn <T, U>    __builtin_is_assignable() -> bool
eval fn <T>       __builtin_is_destructible() -> bool
//  plus the shape predicates: is_void, is_pointer, is_reference, is_array,
//  is_function, is_enum, is_class, is_union, is_integral, is_floating_point,
//  is_signed, is_unsigned.
//  TODO: enumerate. Mechanical, do it on the plane.

//  -- bit operations --------------------------------------------------------
//
//  All lower to LLVM intrinsics. All must be constant-evaluable. All are
//  hot-path for the lexer, BitVector, and the hash maps.
//
eval fn <T> __builtin_ctz(v: T) -> u32
eval fn <T> __builtin_clz(v: T) -> u32
eval fn <T> __builtin_popcount(v: T) -> u32
eval fn <T> __builtin_bswap(v: T) -> T
eval fn <T> __builtin_rotl(v: T, n: u32) -> T
eval fn <T> __builtin_rotr(v: T, n: u32) -> T
eval fn <T> __builtin_bit_ceil(v: T) -> T
eval fn <T> __builtin_bit_width(v: T) -> u32

//  -- overflow-checked arithmetic -------------------------------------------
//
//  Needed for arena size computation and for integer literal constant folding.
//  Missing from every earlier draft.
//
fn <T> __builtin_add_overflow(a: T, b: T, out: *T) -> bool
fn <T> __builtin_sub_overflow(a: T, b: T, out: *T) -> bool
fn <T> __builtin_mul_overflow(a: T, b: T, out: *T) -> bool

//  -- codegen and optimizer hooks -------------------------------------------
fn __builtin_expect(cond: bool, expected: bool) -> bool
fn __builtin_expect_prob(cond: bool, expected: bool, p: f64) -> bool
fn __builtin_unreachable() -> !
fn __builtin_trap() -> !
fn __builtin_assume(cond: bool)
fn __builtin_prefetch(ptr: unsafe *u8, rw: i32, locality: i32)
fn <T> __builtin_addressof(v: ref!(T)) -> *T
eval fn __builtin_is_constant_evaluated() -> bool
eval fn <T> __builtin_constant_p(v: T) -> bool
//        ^ expect matters for the diagnostic and parser-error paths, which are
//          cold and currently unmarked. prefetch matters for the token stream
//          walk.

//  -- termination -----------------------------------------------------------
fn <const N: usize> __builtin_crash(msg: const [char; N], exit_code: i32) -> !
fn <const N: usize> __builtin_signal(msg: const [char; N], signal: SIGNAL) -> !
fn __builtin_abort() -> !
//        ^ two earlier drafts disagreed on `<N: usize>` vs `<const N: usize>`.
//          Using `const` here. Sweep the rest.

//  -- atomics ---------------------------------------------------------------
//
//  Compiler intrinsics, NOT a library type. The ThreadPool's release/acquire
//  ordering depends on the compiler emitting the right fences; a library type
//  wrapping cxx::atomic inherits libc++'s ordering and cannot be self-hosted.
//  MemoryOrder is a language enum, declared above.
//
fn <T> __builtin_atomic_load(ptr: *T, order: MemoryOrder) -> T
fn <T> __builtin_atomic_store(ptr: *T, v: T, order: MemoryOrder)
fn <T> __builtin_atomic_exchange(ptr: *T, v: T, order: MemoryOrder) -> T
fn <T> __builtin_atomic_cas(
    ptr: *T, expected: *T, desired: T,
    succ: MemoryOrder, fail: MemoryOrder
) -> bool
fn <T> __builtin_atomic_fetch_add(ptr: *T, v: T, order: MemoryOrder) -> T
fn <T> __builtin_atomic_fetch_sub(ptr: *T, v: T, order: MemoryOrder) -> T
fn <T> __builtin_atomic_fetch_and(ptr: *T, v: T, order: MemoryOrder) -> T
fn <T> __builtin_atomic_fetch_or(ptr: *T, v: T, order: MemoryOrder) -> T
fn <T> __builtin_atomic_fetch_xor(ptr: *T, v: T, order: MemoryOrder) -> T
fn __builtin_atomic_fence(order: MemoryOrder)
eval fn <T> __builtin_atomic_is_lock_free() -> bool

//  -- source location -------------------------------------------------------
//
//  Compiler-provided, impossible as a library. The parser already has BiFile,
//  BiLine, BiColumn, BiFunction, BiModule token kinds, so the surface syntax
//  exists — these are the lowering targets.
//
fn __builtin_source_file() -> StrRef
fn __builtin_source_line() -> u32
fn __builtin_source_column() -> u32
fn __builtin_source_function() -> StrRef

//===----------------------------------------------------------------------===//
//  core::                                                             PARTIAL
//===----------------------------------------------------------------------===//

module core {

    //  -- allocator protocol ------------------------------------------------
    //
    //  Note what is NOT here: containers do not take an allocator parameter.
    //  The allocator is ambient, set by @mem::set_allocator or
    //  @mem::set_scoped_allocator. That is what lets `[T]` sugar work at all —
    //  there is nowhere in `[T]` to spell a generic allocator argument.
    //
    virtual interface Allocator {
        @Crashes
        fn alloc(self, size: usize, align: usize) -> unsafe *u8
        fn try_alloc(self, size: usize, align: usize) -> unsafe *u8?

        @Crashes
        fn realloc(self, ptr: unsafe *u8, old_size: usize, new_size: usize,
                   align: usize) -> unsafe *u8
        fn try_realloc(self, ptr: unsafe *u8, old_size: usize, new_size: usize,
                       align: usize) -> unsafe *u8?

        fn free(self, ptr: unsafe *u8, size: usize)
    }
    //  TODO: @Crashes vs the panic effect — are these the same mechanism?
    //        If @Crashes means "terminates the process, not catchable" then it
    //        is distinct from panic and EffectPropagation must not track it.
    //        Say so explicitly; the answer changes what the checker does.

    virtual interface ScopedAllocator derives Allocator {
        /// frees everything this allocator handed out. Runs at scope exit.
        fn op delete(self)
    }

    /// A ScopedAllocator variant for embedded and bare-metal targets: static
    /// functions only, no indirection, no vtable. The compiler replaces
    /// @create with a direct static call plus placement construction.
    /// Tether treats it identically to a ScopedAllocator for lifetime
    /// tracking; the difference is a codegen concern.
    interface FreestandingAllocator {
        static fn alloc(size: usize, align: usize) -> unsafe *u8
        static fn free(ptr: unsafe *u8, size: usize)
    }

    //  -- LibcAllocator -----------------------------------------------------
    //
    //  The default global allocator. System malloc, deliberately.
    //
    //  Why not mimalloc/jemalloc bundled by default:
    //    - interop: a C++ library free()ing a Kairo pointer must reach the
    //      same heap. Sharing the platform allocator is the only way both
    //      directions of interop stay sane by default.
    //    - binary size and startup: ~100KB and init work on every hello-world.
    //      Rust shipped jemalloc and removed it in 1.32 for this reason.
    //    - 14 cross-compilation sysroots each with their own quirks.
    //    - freestanding targets do not have it; a second default is needed
    //      anyway.
    //
    //  Why this is fine: the hot allocation path is the arena, reached through
    //  a scoped allocator. The global allocator only sees long-lived,
    //  low-frequency allocations. If the global default needed to be fast, the
    //  scoped mechanism would be redundant.
    //
    class LibcAllocator impl Allocator, ScopedAllocator {
        fn alloc(self, size: usize, align: usize) -> unsafe *u8 {
            var ptr = self.try_alloc(size, align)
            if !ptr? {
                __builtin_crash("LibcAllocator: out of memory", 1)
            }
            return ptr!
        }

        fn try_alloc(self, size: usize, align: usize) -> unsafe *u8? {
            return if align <= __builtin_max_align() {
                __builtin_alloc(size)
            } else {
                __builtin_alloc_align(size, align)
            }
        }

        fn realloc(self, ptr: unsafe *u8, old_size: usize, new_size: usize,
                   align: usize) -> unsafe *u8 {
            var p = self.try_realloc(ptr, old_size, new_size, align)
            if !p? {
                __builtin_crash("LibcAllocator: out of memory during realloc", 1)
            }
            return p!
        }

        fn try_realloc(self, ptr: unsafe *u8, old_size: usize, new_size: usize,
                       align: usize) -> unsafe *u8? {
            //  libc realloc gives no alignment guarantee beyond max_align_t.
            //  For over-aligned blocks: alloc-new, copy, free-old.
            if align > __builtin_max_align() {
                var fresh = __builtin_alloc_align(new_size, align)
                if !fresh? { return null }
                var n = new_size if new_size < old_size else old_size
                __builtin_copy(fresh!, ptr, n)
                __builtin_free(ptr)
                return fresh
            }
            return __builtin_realloc(ptr, old_size, new_size)
        }

        fn free(self, ptr: unsafe *u8, size: usize) {
            __builtin_free(ptr)
        }

        fn op delete(self) {
            //  no-op: LibcAllocator holds no state. Present only to satisfy
            //  ScopedAllocator, so `@mem::set_scoped_allocator(LibcAllocator)`
            //  is legal and means "no arena, just malloc".
        }
    }

    //  -- CxxNewAllocator -------------------------------------------------- STUB
    //
    //  Routes to ::operator new / ::operator delete, so Kairo allocations DO
    //  observe a global operator new override in the linked program.
    //
    //  This is the unusual case. By default Kairo allocations are isolated
    //  from such overrides — exported classes carry class-specific operator
    //  new/delete, which take precedence over a global replacement. That
    //  isolation is structural, not a restriction, and it is why `delete p`
    //  from C++ on a Kairo object is correct.
    //
    //  TODO: needs an ffi "c++" path to ::operator new(size_t, align_val_t).
    //        Check what the aligned overload is called on the MSVC side.
    class CxxNewAllocator impl Allocator {
        // TODO: implement CxxNewAllocator
    }

    //  -- ArenaAllocator --------------------------------------------------- STUB
    //
    //  Bump allocator over mmap'd slabs. The workhorse for the compiler's own
    //  AST and for anything with a clear phase boundary.
    //
    //  Design notes:
    //    - Slabs from mmap/VirtualAlloc, not malloc. Malloc'd slabs fragment
    //      the general heap for no reason and cost a header per slab.
    //    - Geometric slab growth, first slab sized by a hint.
    //    - free() is a no-op EXCEPT for the most recent allocation, which can
    //      be popped. That one case is worth having: it makes a failed
    //      speculative parse free.
    //    - realloc in place iff the block is the most recent allocation and
    //      the slab has room. Otherwise alloc-copy, and the old bytes leak
    //      until the arena dies. That is the trade.
    //    - op delete unmaps every slab. Does NOT run destructors — see below.
    //
    //  OPEN: destructors of arena-allocated objects. Two options:
    //    (a) The arena keeps a list of destructor thunks and runs them on
    //        op delete. Costs a pointer pair per non-trivial allocation.
    //    (b) Arena allocation is restricted to trivially-destructible types,
    //        enforced by sema. Cheaper and catches bugs, but rules out
    //        arena-allocating anything holding a String or a Vec.
    //    Stage 0's arena does (b) implicitly by convention. Decide whether
    //    that becomes a rule.
    //
    class ArenaAllocator impl Allocator, ScopedAllocator {
        // TODO: implement ArenaAllocator
    }

    //  -- NullAllocator ---------------------------------------------------- STUB
    //
    //  Every operation crashes. The freestanding default, so that @create
    //  without a scoped allocator is a diagnosable error rather than a link
    //  failure or a null deref.
    //
    //  TODO: better as a compile-time absence than a runtime crasher? If
    //        freestanding has NO global allocator at all, sema can reject
    //        @create at the call site with a real message. That is strictly
    //        better than a crash, and it is the same shape as the scoped
    //        allocator question above.
    class NullAllocator impl Allocator {
        // TODO: implement NullAllocator
    }
}

//===----------------------------------------------------------------------===//
//  MEMORY MACRO FAMILY                                                PARTIAL
//===----------------------------------------------------------------------===//
//
//  These were @InlineSource functions in an earlier draft and are macros now.
//  Macro is the current direction: the scoped/global branch lives in one
//  place, and the expansion is visible in --print-ast.
//
//  @create    allocate and construct
//  @destroy   destruct and deallocate
//  @alloc     allocate raw storage
//  @free      deallocate raw storage
//  @realloc   resize an allocation
//  @construct construct at a location
//  @destruct  destruct at a location
//

macro memcpy!(dst, src, size)   { __builtin_copy(dst, src, size);      }
macro memmove!(dst, src, size)  { __builtin_move_mem(dst, src, size);  }
macro memset!(ptr, value, size) { __builtin_set_mem(ptr, value, size); }

/// \brief `@create T(args...)` -> construct-in-fresh-storage.
///
/// Expands to:
///   __builtin_construct_at<T>(<alloc>(sizeof T, alignof T), args...)
/// where <alloc> is the scoped allocator if one is active, else the global.
///
/// NOTE per OPEN DECISION 1 the scoped test is a RUNTIME branch, not `eval if`.
macro @create(node: *AST::CallExpression) {
    var node_name = AST::ToCode(node.name);
    var construct = AST::ParseCallExpr(
        f"__builtin_construct_at<{node_name}>(std::__alloc_for(sizeof {node_name}, alignof {node_name}))"
    );
    construct.arguments.append_all(node.arguments);
    AST::Transform(node, construct);
}

//  TODO: @create [i32; 10] — the array form. Needs a distinct expansion:
//        element-wise construct, with a trivial-construct fast path that
//        collapses to a single alloc. The macro must dispatch on whether its
//        operand is an array type. Currently unimplemented.
//
//  TODO: @destroy, @alloc, @free, @realloc, @construct, @destruct.
//        Each needs the same runtime scoped/global branch. Write @destroy
//        next; it is the one with a subtlety — it must run the destructor
//        BEFORE deallocating, and the deallocation size must match what was
//        allocated, which means the macro needs the static type.

//===----------------------------------------------------------------------===//
//  std:: — allocation entry points                                    PARTIAL
//===----------------------------------------------------------------------===//

module std {

    /// The single dispatch point every allocating macro routes through.
    /// One place to get the scoped/global branch right.
    @always_inline
    fn __alloc_for(size: usize, align: usize) -> unsafe *u8 {
        if __builtin_has_scoped_alloc() {
            return __builtin_scoped_allocator().alloc(size, align)
        }
        return __builtin_global_allocator().alloc(size, align)
    }

    @always_inline
    fn __try_alloc_for(size: usize, align: usize) -> unsafe *u8? {
        if __builtin_has_scoped_alloc() {
            return __builtin_scoped_allocator().try_alloc(size, align)
        }
        return __builtin_global_allocator().try_alloc(size, align)
    }

    @always_inline
    fn __free_for(ptr: unsafe *u8, size: usize) {
        if __builtin_has_scoped_alloc() {
            __builtin_scoped_allocator().free(ptr, size)
            return
        }
        __builtin_global_allocator().free(ptr, size)
    }

    //  TODO: __realloc_for, and decide whether it is allowed to fall back to
    //        alloc-copy-free when the allocator cannot resize in place. For
    //        the arena it must; for libc it must not (realloc already does).

//===----------------------------------------------------------------------===//
//  Nullable<T>                                                        SETTLED
//===----------------------------------------------------------------------===//
//
//  Storage strategy for `T?`. Three specializations selected by `requires`:
//    * safe-pointer T  -> niche-filled, null == 0x0, no tag, sizeof(T).
//    * niche-capable T -> niche-filled in a spare bit pattern (e.g. bool).
//    * everything else -> tagged { value; present } fallback.
//
//  This type exposes ONLY primitives. The surface operators `?`, `?.`, `??`
//  and the `unwrap!()` macro are sema desugarings that call these primitives.
//  __value() does NOT null-check; the desugars gate it with is_null() or a
//  narrowing proof.
//

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

    //  TODO: replace both families with __builtin_is_safe_pointer /
    //        __builtin_is_unsafe_pointer. Eight specializations each, and the
    //        list grows with every qualifier combination. Each query is a
    //        template instantiation, and pointer predicates are queried
    //        constantly.

    //  Default: tagged fallback. Unconstrained, matches any T with no niche.
    //  A more-specialized specialization wins when its `requires` holds.
    struct <T> NullableStorage {
        var value:   T
        var present: bool
    }

    //  NOTE  deliberately no @packed tagged specialization. Kairo follows C++
    //        layout rules, so a non-@packed T already has
    //        sizeof(T) % alignof(T) == 0. For align-1 T the tagged form is
    //        identical packed or not. For align>1 T, packing saves bytes only
    //        by misaligning `value` in aggregates — a hidden access cost we do
    //        not impose by default. A user who wants it writes @packed on
    //        their own declaration.
    extend <T> NullableStorage {
        @copy
        inline fn NullableStorage(self, other: Self) {
            self.value = other.value; self.present = other.present
        }
        inline fn NullableStorage(self, value: T) { self.value = value; self.present = true }
        inline fn NullableStorage(self)           { self.value = T(); self.present = false }

        inline static fn null() -> NullableStorage<T> = NullableStorage()

        inline fn is_null(self) -> bool = !self.present

        /// UNCHECKED. Precondition: !is_null(). Sema-only call site.
        inline fn __value(self) -> T = self.value

        inline fn op == (self, other: Self) -> bool =
            self.present == other.present && ((!self.present) || self.value == other.value)
        inline fn op != (self, other: Self) -> bool = !(self == other)
    }

    //  Safe-pointer specialization: niche-filled. null == 0x0. No tag.
    @__intrinsic_always_safe()   // suppress Tether on the raw-pointer slot; std-only
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

        /// UNCHECKED. Precondition: !is_null(). Reinterprets the raw slot as
        /// the non-null P. Sema-only call site; the desugar proves non-null.
        inline fn __value(self) -> P = self.ptr as P

        inline fn op == (self, other: Self) -> bool = self.ptr == other.ptr
        inline fn op != (self, other: Self) -> bool = self.ptr != other.ptr
    }

    //  bool specialization: niche in the spare bit patterns. bool uses 0/1;
    //  0x02 is the None pattern. One byte, no tag.
    @__intrinsic_always_safe()
    struct <> NullableStorage<bool> {
        priv var byte: u8   // 0x00 == Some(false), 0x01 == Some(true), 0x02 == None
    }

    @__intrinsic_always_safe()
    extend <> NullableStorage<bool> {
        eval INVALID: u8 = 0x02

        @copy
        inline fn NullableStorage(self, other: Self) { self.byte = other.byte }
        inline fn NullableStorage(self, value: bool) { self.byte = value as u8 }
        inline fn NullableStorage(self)              { self.byte = INVALID }

        inline static fn null() -> NullableStorage<bool> = NullableStorage()

        inline fn is_null(self) -> bool = self.byte == INVALID

        /// UNCHECKED. Precondition: !is_null(). byte is 0 or 1 here.
        inline fn __value(self) -> bool = self.byte != 0x00

        inline fn op == (self, other: Self) -> bool = self.byte == other.byte
        inline fn op != (self, other: Self) -> bool = self.byte != other.byte
    }

    //  TODO: more niche specializations worth having:
    //        - enum T with fewer variants than its underlying type can hold:
    //          use the first unused discriminant. Needs
    //          __builtin_underlying_type plus a variant count intrinsic.
    //        - references (if Kairo has a distinct reference type): same as
    //          safe pointer.
    //        - a general __builtin_niche_of<T> that reports a spare bit
    //          pattern if one exists. Would collapse all of the above into one
    //          specialization. Consider once the list passes four.

    /// The one user-facing type. Methods live here; storage is delegated.
    struct <T> Nullable {
        var storage: NullableStorage<T>

        fn is_null(self) -> bool { return self.storage.is_null() }

        // TODO: unwrap (panics on null), unwrap_or, unwrap_or_else, map,
        //       and_then, filter, ok_or. Decide which are methods and which
        //       are sema desugars — `??` is a desugar, `map` probably is not.
    }

//===----------------------------------------------------------------------===//
//  Panickable<T>                                                          STUB
//===----------------------------------------------------------------------===//
//
//  The result of a fallible function. A tagged union of the success value and
//  the declared panic set.
//
//  Interop contract (see interop spec):
//    - Kairo never unwinds. Every emitted function is noexcept, structurally.
//    - C++ callers get the value API, plus a method on this type that converts
//      the error tag into a thrown C++ exception. That method is GENERATED
//      C++: the throw originates on the C++ side of the boundary, so the
//      noexcept guarantee on the real entry point is untouched.
//
//  TODO: shape. Is the error side the full effect set as a variant, or an
//        erased error value with the set recorded only in the type? The former
//        makes exhaustive `match` on the error possible, which is the point of
//        a typed effect system. The latter is smaller.
//
//  TODO: layout. This is returned by every fallible function, so it is on the
//        hottest ABI path in the language. It must fit in registers for small
//        T. Niche-fill the tag where possible — same machinery as
//        NullableStorage.

    struct <T, E> Panickable {
        // TODO: implement Panickable
    }

//===----------------------------------------------------------------------===//
//  StrRef                                                                 STUB
//===----------------------------------------------------------------------===//
//
//  Non-owning view over UTF-8 bytes. The most-used type in a compiler, so the
//  API surface matters more than the implementation.
//
//  Representation: pointer + byte length. No null-termination assumption.
//  Trivially copyable, trivially destructible, passed in registers.
//
//  Mirrors `string`'s codepoint/byte split:
//    s[i]        -> char (u32 scalar) at CODEPOINT index i.  O(n) for a
//                   StrRef, since no breadcrumb cache travels with a view.
//    s.bytes[i]  -> u8 at BYTE offset i.  O(1) always.
//    for c in s  -> sequential codepoint decode. The right default.
//
//  TODO: decide whether StrRef carries an optional breadcrumb pointer when it
//        was sliced from a literal-backed string. Free O(1) indexing when
//        available, one extra word when not. Probably not worth it — a view
//        should stay two words.
//
    struct StrRef {
        priv var data: unsafe *u8
        priv var len:  usize     // BYTES, not codepoints

        // TODO: construction — from a literal, from string, from (ptr, len).
        // TODO: len_bytes, len_codepoints, is_empty
        // TODO: bytes[i], codepoint at i, iteration
        // TODO: starts_with, ends_with, contains
        // TODO: find, rfind, find_any_of  (byte offsets, not codepoint)
        // TODO: substr(byte_start, byte_len) — MUST validate it does not split
        //       a codepoint, or must be documented as raw and unchecked.
        //       Decide which. A checked substr that panics is safer; an
        //       unchecked one is what the lexer wants.
        // TODO: split(delim) -> iterator. Blocked on the Iter<T> protocol.
        // TODO: trim, trim_start, trim_end
        // TODO: op ==, op !=, op <=>  (byte-wise, not collation)
        // TODO: hash — must agree with string's hash so a StrRef can look up
        //       a String key without allocating. This is load-bearing for the
        //       symbol table; get it right.
    }

//===----------------------------------------------------------------------===//
//  Slice<T> — the [T;] sugar                                              STUB
//===----------------------------------------------------------------------===//
//
//  OPEN DECISION 2 — the const/mut distinction.
//
//  `[T;]` is documented as read-write. So what is the read-only spelling?
//    (a) `const [T;]` — const applies to the view, meaning the elements are
//        not writable through it. Reads naturally, matches C++ intuition.
//    (b) a separate type. Explicit, but doubles every signature that takes a
//        view.
//    (c) `[const T;]` — const on the element type. Most precise, least
//        familiar.
//
//  This is a type-system decision, not a library one, and every function that
//  takes a view depends on it. SETTLE THIS FIRST.
//
    struct <T> Slice {
        priv var data: unsafe *T
        priv var len:  usize

        // TODO: len, is_empty, op [], first, last
        // TODO: subslice(start, len) — bounds-checked or not? Under Tether the
        //       bounds check is provable-away in most cases, so checked is the
        //       right default.
        // TODO: iteration. Blocked on Iter<T>.
        // TODO: from a Vec, from an Array, from (ptr, len) in an unsafe block
        // TODO: op ==, contains, find  (require T: Equatable)
    }

//===----------------------------------------------------------------------===//
//  Vec<T> — the [T] sugar                                                 STUB
//===----------------------------------------------------------------------===//
//
//  The first real container. Everything else depends on it: Slice is a view
//  over it, Array shares its element-access sema, Map and Set need its growth
//  machinery.
//
//  Representation: data pointer, length, capacity. Three words.
//
//  DESUGARING CONSTRAINT: `[T]` must resolve to a CONCRETE named type, once,
//  with no alias chain and no template specialization the frontend has to
//  instantiate to learn the layout. If the frontend must instantiate to answer
//  "what is the layout of [T]", there is an instantiation in the parse path.
//
//  LITERAL CONSTRUCTION: `[1, 2, 3]` has a known element count at parse time.
//  Emit reserve-then-fill, not N pushes with N growth checks. Cheap to get
//  right now, annoying to retrofit.
//
//  GROWTH PATH — the part that needs the intrinsics:
//    if __builtin_is_trivially_relocatable<T>():
//        alloc new, memcpy, free old.  No destructors, no moves.
//    else:
//        alloc new, move-construct each element, destruct each old, free old.
//  Getting this wrong is the difference between a fast container and a slow
//  one, and it cannot be written until the trait intrinsics exist.
//
//  SmallVec<T, N>: inline capacity for the first N elements. NOT optional —
//  LLVM's SmallVector exists because compiler workloads are full of 0–4
//  element sequences, and the difference is 10–20% wall clock on a real
//  compiler. Open question: separate type, or `Vec<T>` with an N parameter
//  defaulting to 0? The sugar `[T]` can only spell the latter.
//
//  HAZARD: SmallVec move semantics. Moving a container with an inline buffer
//  under @move is subtle and every bug is a use-after-free. Write the move
//  path first and test it before anything else.
//
    struct <T> Vec {
        priv var data: unsafe *T
        priv var len:  usize
        priv var cap:  usize

        // -- construction
        // TODO: Vec(), Vec(capacity: usize), from a literal, @copy, @move
        // TODO: op delete — destruct live elements, then free. For trivially
        //       destructible T skip the loop entirely.

        // -- capacity
        // TODO: len, capacity, is_empty
        // TODO: reserve(n), reserve_exact(n), shrink_to_fit
        // TODO: growth policy — 2x or 1.5x? 1.5x allows reuse of freed blocks
        //       under some allocators; 2x has fewer reallocations. Pick one
        //       and write down why.

        // -- access
        // TODO: op [] — bounds-checked. Under Tether the check is
        //       provable-away in the common case, so checked is the default.
        // TODO: get(i) -> T?, first, last, data(), as_slice()

        // -- mutation
        // TODO: push, pop, insert, remove, swap_remove, clear, resize, truncate
        // TODO: append(other), extend_from_slice
        // TODO: clear() on non-trivial T is N `delete`s with no deallocation.
        //       pop() is one. Write these in terms of `delete` explicitly
        //       rather than leaving it implicit — it reads obvious now and is
        //       ambiguous in six months.

        // -- iteration
        // TODO: blocked on Iter<T>.
    }

//===----------------------------------------------------------------------===//
//  Map<K,V> / Set<K> — the {K:V} and {T} sugar                            STUB
//===----------------------------------------------------------------------===//
//
//  Open addressing. Robin Hood or swiss-table layout. NOT chaining — a chained
//  map is the wrong shape for every compiler workload.
//
//  Write ONE core and specialize: Set<K> is Map<K, void> with the value
//  storage elided. Do not write two.
//
//  DenseMap semantics: tombstones, power-of-two capacity, and a sentinel
//  scheme for empty/tombstone keys (either a getEmptyKey/getTombstoneKey
//  protocol or a separate control byte array — swiss tables use the latter and
//  it is friendlier to arbitrary K).
//
//  OPEN DECISION 3 — the iterator invalidation contract. WRITE IT DOWN.
//  Compiler code inserts while iterating constantly and gets away with it
//  under DenseMap's rules, which differ from unordered_map's. Whatever the
//  rule is, it must be explicit, because code will depend on it either way.
//    - Does insert invalidate all iterators? Only on rehash?
//    - Are references to values stable across insert? (Open addressing says
//      no; that surprises people coming from unordered_map.)
//    - Is erase-during-iteration legal?
//
//  LITERAL CONSTRUCTION: `{1: 2, 3: 4}` has a known entry count. Reserve then
//  fill, same as Vec.
//
//  AMBIGUITY: `{}` alone is ambiguous between an empty set, an empty map, and
//  a block. Require a type annotation and error otherwise, rather than
//  defaulting to one and surprising people.
//
    struct <K, V> Map {
        // TODO: implement Map
    }

    struct <K> Set {
        // TODO: implement Set — Map<K, void> with value storage elided
    }

//===----------------------------------------------------------------------===//
//  StringMap                                                              STUB
//===----------------------------------------------------------------------===//
//
//  Map specialized for StrRef keys with interned storage. Symbol tables, macro
//  tables, and identifier tables all want this and none of them want a general
//  Map<String, V> that allocates a String per key.
//
//  Pairs with an interner: `StrRef intern(StrRef)` backed by an arena plus a
//  hash set. Every identifier goes through it, and pointer equality for
//  identifier comparison is a load-bearing optimization in name resolution.
//
//  TODO: does the interner live here or in core? It needs an arena, which
//        makes it allocator-aware in a way nothing else in std is.
//
    struct <V> StringMap {
        // TODO: implement StringMap
    }

//===----------------------------------------------------------------------===//
//  BitVector                                                              STUB
//===----------------------------------------------------------------------===//
//
//  Dataflow, liveness, and the verify passes all want one. Word-backed, with
//  the bit ops from the intrinsic list.
//
//  TODO: SmallBitVector variant with inline words? Same argument as SmallVec.
//        Probably yes, probably later.
//
    struct BitVector {
        // TODO: implement BitVector
    }

//===----------------------------------------------------------------------===//
//  Deque / ring buffer                                                    STUB
//===----------------------------------------------------------------------===//
//
//  Worklist algorithms need one. A ring buffer covers every use in the
//  compiler — cxx::deque's stable-reference semantics are not needed and are
//  expensive to provide.
//
    struct <T> Deque {
        // TODO: implement Deque as a ring buffer
    }

//===----------------------------------------------------------------------===//
//  FunctionRef<Sig>                                                       STUB
//===----------------------------------------------------------------------===//
//
//  Non-owning callable view. RecursiveASTVisitor and TreeTransform callbacks
//  want this. Non-owning is the whole point: cxx::function's allocation is a
//  real cost in visitor-heavy code.
//
//  Representation: callable pointer + type-erased invoke thunk. Two words,
//  trivially copyable.
//
//  HAZARD: it is a VIEW. Storing one past the callee's lifetime is a dangling
//  reference. Under Tether this is catchable; document it loudly regardless.
//
    struct <Sig> FunctionRef {
        // TODO: implement FunctionRef
    }

//===----------------------------------------------------------------------===//
//  Hashing                                                                STUB
//===----------------------------------------------------------------------===//
//
//  TODO: pick a 64-bit hash and port it. xxhash or wyhash. Do NOT write one.
//  TODO: hash_combine.
//  TODO: STABILITY DECISION — is the hash stable across runs? Across compiler
//        versions? Stable-across-runs makes debugging reproducible and lets
//        hashes go in cache files. Unstable allows seeding against HashDoS,
//        which is irrelevant for a compiler. Pick stable, say so.
//  TODO: StrRef and String must hash identically. Load-bearing for the symbol
//        table.

//===----------------------------------------------------------------------===//
//  Algorithms                                                             STUB
//===----------------------------------------------------------------------===//
//
//  The short list. A compiler needs these and almost nothing else.
//
//  TODO: sort — port pdqsort. Do not write one.
//  TODO: stable_sort
//  TODO: lower_bound, upper_bound, binary_search
//  TODO: find, find_if, any_of, all_of, none_of, count_if
//  TODO: min, max, clamp
//  TODO: swap, exchange
//  TODO: reverse, rotate, unique
//
//  NOT here: move and forward live in the language, not the library.

//===----------------------------------------------------------------------===//
//  Formatting                                                             STUB
//===----------------------------------------------------------------------===//
//
//  TODO: typed formatter. Not printf, not iostream. Compile-time format string
//        checking if the eval machinery can carry it.
//  TODO: float formatting — shortest round-trip. Port Ryu or Grisu. Everyone
//        underestimates this; it is genuinely hard and a wrong implementation
//        is a silent correctness bug in emitted IR.
//  TODO: integer parse and format, all bases.
//  TODO: UTF-8 decode/encode, and codepoint display width. The diagnostic
//        renderer's byte-exact carets depend on the width function.

//===----------------------------------------------------------------------===//
//  NOT IN THE STANDARD LIBRARY
//===----------------------------------------------------------------------===//
//
//  For the record, so nobody adds them later:
//
//  Tuple            — compiler-generated struct per structural encoding. `.0`
//                     lowers to a plain field access. Zero library code.
//  move / forward   — language, not library.
//  Atomics          — intrinsics, not a library type. MemoryOrder is a
//                     language enum.
//  Time             — useful, not integral. Goes in the fourth layer.
//  Filesystem       — same.
//  Regex, random,
//  complex, locale  — same, and several of them should not exist at all.
//
//  Mutex, threads   — these DO belong in std: useful to most programs, and not
//                     reimplementable without dropping to the OS.
//                     TODO: draft them. Thin pthread/Win32 wrappers.
//                     No future/promise — nothing in the compiler used them.

}

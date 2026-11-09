# Allocators

Allocation goes through [`@create T()`](/docs/language/pointers/#heap-allocation) and `@destroy`; both route to the allocator in effect at that point. `@destroy p` runs the destructor (`fn op finally`) of `*p` and returns the memory to the allocator (`@free p`). Kairo has no `delete` expression, and `x.finally()` runs the destructor early without freeing. See [Freeing memory](/docs/language/classes-lifecycle/#freeing-memory). Three kinds exist, chosen by scope: **global**, **scoped** and **freestanding**.

### Global allocator

The default for [`@create T()`](/docs/language/pointers/#heap-allocation) and all standard-library heap operations. Out of the box it is `System`, the runtime's bundled [mimalloc](https://github.com/microsoft/mimalloc) (see [Sharing the heap with C and C++](#sharing-the-heap-with-c-and-c)). A program replaces it with `@set_global_allocator`, on a line of its own at file scope:

```kairo
class Arena {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { ... }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { ... }
    static fn resize(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> bool { ... }
    static fn realloc(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 { ... }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { ... }
}

@set_global_allocator(Arena)
```

The choice is made when the program **links**, not per file: every file's allocations, and those of every library linked in, go to `Arena` without any of them mentioning it. The argument must be a class or struct with the five static functions above (the `FullAllocator` interface); a missing one is an error at the attribute.

**One per program.** Exactly one linked file may set it. A second in the same file, or in another file of the same build, is a compile error naming both; two objects compiled separately that each set it are a link error naming both objects. A library should not set the global allocator: that decision belongs to the program. Libraries that want their own memory use a [scoped allocator](#scoped-allocator) or the `_in` functions with an allocator of their own.

How it works, and what is fixed for compatibility, is under [The global allocator ABI](#the-global-allocator-abi).

### Scoped allocator

An allocator with RAII semantics it frees everything it allocated when it leaves scope. Set with `@mem::set_scoped_allocator(MyAllocator)` on a function or block.

```kairo
@mem::set_scoped_allocator(ArenaAllocator)
fn process_frame() {
    var *a = @create Mesh(vertices)
    var *b = @create Texture(pixels)
    // freed wholesale when process_frame returns
}
```

A pointer allocated through a scoped allocator that escapes the allocator's scope is [**Tier N**](/docs/language/tether-proof-model/#the-residual-table). The arena frees the memory at scope end; no smart pointer and no runtime check rescues a pointer to freed arena memory (and across threads, the free races the access). The escape increments the allocation's epoch at the scope close, so the escaping pointer fails C1 by the same machinery as any other dangling pointer. The only fix is restructuring: allocate through the global allocator, or move the scoped boundary outward.

### Freestanding allocator

A scoped-allocator variant for embedded and bare-metal targets, conforming through `static` functions only no indirection, no vtable. The compiler replaces `@create T()` with a direct static call plus placement construction. Tether treats freestanding allocators identically to scoped allocators for lifetime tracking; the difference is a codegen concern.

---

## The Allocator Interface

A type passed to `@set_global_allocator` or `@mem::set_scoped_allocator`, or used as a freestanding allocator, must satisfy `Allocator` (and `@set_global_allocator` needs the whole `FullAllocator`: `Resizer`, `Reallocator` and `ZeroAllocator` too). Conformance is [structural](/docs/language/interfaces/#structural-conformance) and goes through static functions only, so an allocator carries no instance state and no vtable:

```kairo
interface Allocator {
    static fn alloc(size: usize, align: usize) -> unsafe *u8
    static fn free(ptr: unsafe *u8, size: usize, align: usize)
}

interface Reallocator derives Allocator {
    static fn realloc(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8
}
```

An allocator that does not conform to `Reallocator` is grown with `alloc`, a copy, and `free`.

This is not the same thing as the `Heap` example on the Interfaces page. That is a [virtual interface](/docs/language/interfaces/#virtual-interfaces): instance-based, called through a pointer with dynamic dispatch. `Allocator` is static and resolved at compile time.

---

## The global allocator ABI

The global allocator is five C symbols. The builtin's `Global` calls them; which allocator answers is decided by the linker:

```c
unsigned char *kairo_global_alloc(size_t size, size_t align);
void           kairo_global_free(unsigned char *ptr, size_t size, size_t align);
bool           kairo_global_resize(unsigned char *ptr, size_t old_size, size_t new_size, size_t align);
unsigned char *kairo_global_realloc(unsigned char *ptr, size_t old_size, size_t new_size, size_t align);
unsigned char *kairo_global_alloc_zeroed(size_t size, size_t align);
```

- The runtime defines all five **weakly**, as `System`: mimalloc's allocation, free, realloc and zeroed allocation up to an alignment of `2 * sizeof(void *)`, its aligned variants past it. `resize` grows nothing and keeps any shrink, except a shrink from above 128 words to 128 words or less, which it refuses (`false`) so `realloc` moves the block: mimalloc's small free cannot release a block from a large page.
- The file that writes `@set_global_allocator(A)` defines all five **strongly**, each a forwarder to `A`'s static function of the same name. A strong definition beats a weak one, so the program gets `A`. Two strong definitions are the duplicate-symbol error described above.
- C or C++ code can supply the global allocator the same way: define the five symbols (with C linkage) in any object of the link.
- Without LTO, a call through `Global` is one direct call to the symbol. With LTO the forwarder, and `A`'s functions where they are inline, inline into the caller.

The contract is `Allocator`'s: `align` is a power of two and `size` is never 0 (the front end handles both before an allocator is reached); `free` gets the size and alignment the block was made with, or the new size of its last successful `resize`/`realloc`; failure is a null return, never an abort; a failed `resize` or `realloc` leaves the block as it was; every function is thread-safe. `resize` never moves the block (`false`: nothing changed); `realloc` may (null: nothing changed). The names, the argument order and these types are fixed across compiler versions, so objects built by different Kairo releases, and hand-written C, link together.

### `ScopeFrame`

A [scoped allocator](#scoped-allocator) in effect is one `ScopeFrame` on the stack of the function that opened it, linked into a per-thread stack (`scope_top`; a plain global on targets with no threads). Allocation goes to the top frame; `free` goes to the frame whose range holds the address, or to the global allocator when none does. Code built by different compiler versions shares this stack, so the frame's layout is ABI: seven pointer-sized fields, in this order, with no padding between them:

| # | Field     | Type                                                          |
|---|-----------|---------------------------------------------------------------|
| 0 | `alloc`   | `unsigned char *(*)(size_t size, size_t align)`                |
| 1 | `free`    | `void (*)(unsigned char *ptr, size_t size, size_t align)`      |
| 2 | `resize`  | `bool (*)(unsigned char *ptr, size_t old, size_t new, size_t align)` |
| 3 | `realloc` | `unsigned char *(*)(unsigned char *ptr, size_t old, size_t new, size_t align)` |
| 4 | `lo`      | `unsigned char *`, the first address the allocator hands out   |
| 5 | `hi`      | `unsigned char *`, one past the last                           |
| 6 | `prev`    | `ScopeFrame *`, the frame below, or null                       |

The four functions are the allocator's static functions, with the same contract as the global symbols. `lo`/`hi` are the allocator's `range()` when the scope opened. Reordering, removing or retyping a field is an ABI break between objects built by different compiler versions.

---

### Sharing the heap with C and C++

On ELF targets (Linux, FreeBSD, NetBSD) and on WebAssembly, the bundled mimalloc also replaces `malloc` and `free` for the whole program, so C, C++ and Kairo share one heap and a block may cross between them: a block `System` allocated may be released by C's `free`. On Windows and Apple targets it does not (those keep the CRT heap and malloc zones): there a block Kairo allocates is freed by Kairo, and a block C or C++ allocates is freed by C or C++.

## Allocators and C++

In the C++ an including file sees (a `kcc` `#include "x.k"`, an `--emit-headers` header), every Kairo class, struct and ADT enum carries class-specific `operator new` and `operator delete`, defined by the compiler (Kairo code cannot define or overload them), that always bind to the global allocator. C++ code can `new` and `delete` Kairo objects directly, a C++ `delete` may free what `@create` made (and `@destroy` what C++ `new`ed), and a C++ global `operator new` override does not affect them. In the other direction, memory that must come from or go to C++'s allocator is allocated with `@cxx::new T(args)` (plain C++ `new`, returning `unsafe *T`) and freed with `@cxx::delete p`, never with `@destroy`. To route Kairo's own allocations through C++'s allocation path instead, set `core::CxxNewAllocator` as the global allocator. See [Allocators & Ownership](/docs/language/c-cpp-memory/) for the details.

## See also

- [Tether](/docs/language/tether/)
- [Pointers](/docs/language/pointers/)
- [Ownership](/docs/language/ownership/)
- [Allocators & Ownership (C++)](/docs/language/c-cpp-memory/)
- [Unsafe](/docs/language/unsafe/)

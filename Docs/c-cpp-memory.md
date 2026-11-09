# Allocators & Ownership

## Allocators and Ownership

Heap ownership crosses the boundary in both directions, using the mechanism C++ already has for exactly this purpose.

### Class-specific `operator new` and `operator delete`

In C++-facing output (an `--emit-headers` `.hh`, or the interface `kcc` produces for `#include "x.k"`), every Kairo class, struct and ADT enum carries class-scope allocation functions bound to Kairo's [global allocator](/docs/language/allocators/#global-allocator). The compiler defines them; Kairo code cannot define or overload them. A Kairo type defines only its constructors and its destructor ([`op finally`](/docs/language/operator-overloading/#finally-operator), which is the C++ destructor, not an allocation function). The module's own object has none: Kairo code frees with `@destroy`, which calls the allocator itself.

```cpp
class MyKairoClass {
public:
    static void *operator new(size_t);
    static void  operator delete(void *, size_t);
    static void *operator new[](size_t);
    static void  operator delete[](void *, size_t);
    ~MyKairoClass();
    // plus the aligned (std::align_val_t), std::nothrow_t and placement forms
};
```

So from C++, the ordinary spelling is the correct one, and it goes through Kairo's allocator, not C++'s:

```cpp
MyKairoClass *p = new MyKairoClass("hi");
delete p;   // runs Kairo's destructor, then returns memory to Kairo's global allocator
```

This works because Kairo emits the class, and therefore emits the [destructor](/docs/language/classes-lifecycle/#destructors---op-finally). `~MyKairoClass` performs Kairo's destruction semantics; C++'s `delete` sequences destructor-then-deallocate, which is the same pair of operations Kairo spells as [`@destroy p`](/docs/language/classes-lifecycle/#freeing-memory). A block `@create` made may be freed by a C++ `delete`, and a block C++ `new` made may be freed by `@destroy`.

The throwing `operator new` forms never return null and never throw: when memory runs out the program stops with `kairo: out of memory` (exit 134), as Kairo's own default out-of-memory hook does. The `std::nothrow_t` forms return null. One limit: a polymorphic type's deleting destructor lives in the module's own object, so a C++ `delete` through a base pointer with a virtual destructor frees with the global `::operator delete`.

Pointer parameters and return values stay raw `*T`. There is no wrapper type, no ABI change, and no cost at the call boundary.

### Global `operator new` overrides do not affect Kairo objects

A class-specific `operator new` takes precedence over a global replacement. A C++ translation unit that overrides global `new`/`delete` (for a pool, an instrumented heap, a leak tracker) therefore does not touch Kairo allocations. The isolation is structural, not a restriction.

### The operators bind to the *global* allocator, always

Kairo's [scoped allocator](/docs/language/allocators/#scoped-allocator) mechanism (`@mem::set_scoped_allocator` is not available yet) works by swapping the allocator the process is currently using. The emitted `operator new` and `operator delete` deliberately **bypass** that indirection and address the global allocator directly.

This matters. Consider a C++ `delete` that happens while a Kairo scoped allocator is active:

```kairo
@mem::set_scoped_allocator(ArenaAllocator)
fn work() {
    call_into_cxx()      // C++ runs `delete p` on a globally-allocated Kairo object
}
```

If `operator delete` followed the ambient allocator, that object would be handed to the arena's deallocator instead of the global one. Binding to the global allocator unconditionally makes the pairing correct regardless of what is active at the call site.

The invariant that makes this sound: **objects reachable from C++ were allocated by the global allocator.** A pointer allocated through a scoped allocator that escapes the allocator's scope is a hard error under [Tether](/docs/language/tether/), so a scoped-allocated object cannot reach a C++ `delete` in the first place.

### Memory that belongs to C++: `@cxx::new` and `@cxx::delete`

`@create` and `@destroy` use Kairo's allocator. Memory that crosses into or comes from C++ code and must follow C++'s own allocation (a type a C++ library allocates and frees itself, a pointer a C++ API takes ownership of) uses the `@cxx::` forms, which lower to plain C++ expressions:

| Kairo | C++ it becomes | Result |
|---|---|---|
| `@cxx::new T(args)` | `new T(args)` | `unsafe *T` |
| `@cxx::new [T; n]` | `new T[n]` | `unsafe *T` |
| `@cxx::delete p` | `delete p` | |
| `@cxx::delete [] p` | `delete[] p` | |

```kairo
var p = @cxx::new Widget(4)   // C++ new (Widget is a class from a C++ header): unsafe *Widget
hand_to_cxx_owner(p)
@cxx::delete p                // C++ delete, for memory C++ gave back
```

Pair them: `@cxx::new` memory is freed with `@cxx::delete`, never `@destroy`, and `@create` memory with `@destroy`, never `@cxx::delete`. The `@cxx::` forms are for C++ types: a Kairo record's heap storage is `@create` / `@destroy` on the Kairo side and C++'s `new` / `delete` on the C++ side (a `@cxx::new` of a Kairo record does not yet pair with a C++ `delete` of it).

### What is still an error

Kairo's own pairing rules and the allocation operators above make `new` / `delete` across the boundary valid. They do not make every deallocation valid:

- `free()` on a pointer from [`@create`](/docs/language/pointers/#heap-allocation): wrong deallocator, no destructor.
- `@destroy` or `@cxx::delete` on a pointer from `@alloc`: `@alloc` returns untyped storage with no constructed object.
- `delete` on an object allocated by a C++ `operator new` override in a TU that predates the Kairo declaration.

These are what the [ownership annotations](#ownership-annotations-in-generated-headers) below are for.

### `CxxNewAllocator`

For code that wants Kairo's *own* allocations to follow C++'s allocation path, so that a global `operator new` override does apply to them, `core` is to provide `CxxNewAllocator`. Not yet: it does not exist. `core::CxxNewAllocator` is an unknown name today (R021E); only a stub sits in a draft file of the standard library.

```kairo
@set_global_allocator(core::CxxNewAllocator)
```

This will be the unusual case, not the default. A global allocator that does exist is a class with the static allocator functions of `builtin::base::alloc` (`alloc`, `free`, `resize`, `realloc`, `alloc_zeroed`). `@set_global_allocator` with such a class works and routes `create` and `destroy` (the functions behind `@create` and `@destroy`) through it. Like any [global allocator](/docs/language/allocators/#global-allocator) it is chosen once per program: one file sets it, and every file and library linked in follows.

### Ownership annotations in generated headers

> [!NOTE]
> Not yet: no emitted declaration carries these attributes today, and the `kairo_alloc` / `kairo_free` functions below are the intended shape, not names that exist. The same holds for the lifetime annotations further down.

Declarations emitted for the C++ side are to carry Clang's ownership attributes, tagged with the Kairo allocator identity:

```cpp
void *kairo_alloc(size_t) __attribute__((ownership_returns(kairo_global)));
void  kairo_free(void *)  __attribute__((ownership_takes(kairo_global, 1)));
```

Clang's static analyzer (`MallocChecker`) uses these to flag mismatched allocation and deallocation across the boundary. Because `kcc` controls the compiler invocation, this checking is available as a driver flag rather than requiring a separate `scan-build` step.

> [!NOTE]
> The allocator identity string is part of the interop contract and is pinned in the ABI specification. Both sides must agree on it.

Kairo's own semantic analysis enforces the same rule independently and produces a Kairo-quality diagnostic. The Clang attributes exist so that C++ consumers benefit too.

### Lifetime annotations

Emitted declarations are to carry `[[clang::lifetimebound]]` and the `[[gsl::Owner]]` / `[[gsl::Pointer]]` pair where the Kairo side can prove the relationship. Unlike the ownership attributes, these are diagnosed during ordinary compilation via `-Wdangling`, so a lifetime relationship proven on the Kairo side becomes a real compile-time warning on the C++ side.

## See also

- [C & C++ Interoperability](/docs/language/c-cpp/)
- [kairo, kcc & Cross-compilation](/docs/language/c-cpp-toolchain/)
- [Calling C and C++ from Kairo](/docs/language/c-cpp-calling/)
- [Using Kairo in C++](/docs/language/c-cpp-exposing/)
- [Exceptions & Panics](/docs/language/c-cpp-exceptions/)
- [ABI Contract & Verification](/docs/language/c-cpp-abi/)
- [Tether](/docs/language/tether/)
- [Ownership](/docs/language/ownership/)

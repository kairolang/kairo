# Allocators & Ownership

## Allocators and Ownership

Heap ownership crosses the boundary in both directions, using the mechanism C++ already has for exactly this purpose.

### Class-specific `operator new` and `operator delete`

Every exported Kairo class carries its own allocation operators, bound to Kairo's [global allocator](/docs/language/allocators/#global-allocator):

```cpp
class MyKairoClass {
public:
    static void *operator new(size_t);
    static void  operator delete(void *);
    static void *operator new[](size_t);
    static void  operator delete[](void *);
    ~MyKairoClass();
};
```

So from C++, the ordinary spelling is the correct one:

```cpp
MyKairoClass *p = new MyKairoClass("hi");
delete p;   // runs Kairo's destructor, then returns memory to Kairo's global allocator
```

This works because Kairo emits the class, and therefore emits the [destructor](/docs/language/classes-lifecycle/#destructors---delete-operators). `~MyKairoClass` performs Kairo's destruction semantics; C++'s `delete` merely sequences destructor-then-deallocate, which is the same pair of operations Kairo spells as [`delete obj`](/docs/language/classes-lifecycle/#delete-does-not-free) followed by `@free`.

Pointer parameters and return values stay raw `*T`. There is no wrapper type, no ABI change, and no cost at the call boundary.

### Global `operator new` overrides do not affect Kairo objects

A class-specific `operator new` takes precedence over a global replacement. A C++ translation unit that overrides global `new`/`delete` (for a pool, an instrumented heap, a leak tracker) therefore does not touch Kairo allocations. The isolation is structural, not a restriction.

### The operators bind to the *global* allocator, always

Kairo's [scoped allocator](/docs/language/allocators/#scoped-allocator) mechanism works by swapping the allocator the process is currently using. The emitted `operator new` and `operator delete` deliberately **bypass** that indirection and address the global allocator directly.

This matters. Consider a C++ `delete` that happens while a Kairo scoped allocator is active:

```kairo
@mem::set_scoped_allocator(ArenaAllocator)
fn work() {
    call_into_cxx()      // C++ runs `delete p` on a globally-allocated Kairo object
}
```

If `operator delete` followed the ambient allocator, that object would be handed to the arena's deallocator instead of the global one. Binding to the global allocator unconditionally makes the pairing correct regardless of what is active at the call site.

The invariant that makes this sound: **objects reachable from C++ were allocated by the global allocator.** A pointer allocated through a scoped allocator that escapes the allocator's scope is a hard error under [Tether](/docs/language/tether/), so a scoped-allocated object cannot reach a C++ `delete` in the first place.

### What is still an error

The operators fix `new`/`delete`. They do not make every deallocation valid:

- `free()` on a pointer from [`@create`](/docs/language/pointers/#heap-allocation): wrong deallocator, no destructor.
- `delete` on a pointer from `@alloc`: `@alloc` returns untyped storage with no constructed object.
- `delete` on an object allocated by a C++ `operator new` override in a TU that predates the Kairo declaration.

These are what the [ownership annotations](#ownership-annotations-in-generated-headers) below are for.

### `CxxNewAllocator`

For code that wants Kairo's *own* allocations to follow C++'s allocation path, so that a global `operator new` override does apply to them, `core` provides `CxxNewAllocator`:

```kairo
@mem::set_allocator(core::CxxNewAllocator)
```

This is the unusual case, not the default. The [intentional friction](/docs/language/allocators/#global-allocator) rule applies: the annotation must appear at the top of every file in the affected dependency graph.

### Ownership annotations in generated headers

Declarations emitted for the C++ side carry Clang's ownership attributes, tagged with the Kairo allocator identity:

```cpp
void *kairo_alloc(size_t) __attribute__((ownership_returns(kairo_global)));
void  kairo_free(void *)  __attribute__((ownership_takes(kairo_global, 1)));
```

Clang's static analyzer (`MallocChecker`) uses these to flag mismatched allocation and deallocation across the boundary. Because `kcc` controls the compiler invocation, this checking is available as a driver flag rather than requiring a separate `scan-build` step.

> [!NOTE]
> The allocator identity string is part of the interop contract and is pinned in the ABI specification. Both sides must agree on it.

Kairo's own semantic analysis enforces the same rule independently and produces a Kairo-quality diagnostic. The Clang attributes exist so that C++ consumers benefit too.

### Lifetime annotations

Emitted declarations carry `[[clang::lifetimebound]]` and the `[[gsl::Owner]]` / `[[gsl::Pointer]]` pair where the Kairo side can prove the relationship. Unlike the ownership attributes, these are diagnosed during ordinary compilation via `-Wdangling`, so a lifetime relationship proven on the Kairo side becomes a real compile-time warning on the C++ side.

## See also

- [C & C++ Interoperability](/docs/language/c-cpp/)
- [kairo, kcc & Cross-compilation](/docs/language/c-cpp-toolchain/)
- [Calling C and C++ from Kairo](/docs/language/c-cpp-calling/)
- [Using Kairo in C++](/docs/language/c-cpp-exposing/)
- [Exceptions & Panics](/docs/language/c-cpp-exceptions/)
- [ABI Contract & Verification](/docs/language/c-cpp-abi/)
- [Tether](/docs/language/tether/)
- [Ownership](/docs/language/ownership/)

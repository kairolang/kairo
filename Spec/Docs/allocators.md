# Allocators

Allocation goes through [`@create T()`](/docs/language/pointers/#heap-allocation) and `@destroy`; both route to the allocator in effect at that point. `@destroy p` runs the destructor (`delete *p`) and returns the memory to the allocator (`@free p`); `delete` alone never frees. See [`delete` does not free](/docs/language/classes-lifecycle/#delete-does-not-free). Three kinds exist, chosen by scope: **global**, **scoped** and **freestanding**.

### Global allocator

The default for [`@create T()`](/docs/language/pointers/#heap-allocation) and all standard-library heap operations. Overridable with `@mem::set_allocator(MyAllocator)` at the top of a file.

**Intentional friction**: the override must appear at the top of *every file in the dependency graph* it affects. A library that sets a global allocator forces the annotation onto every transitive dependent. This keeps global-allocator changes visible and pushes library authors toward scoped allocators.

### Scoped allocator

An allocator with RAII semantics it frees everything it allocated when it leaves scope. Set with `@mem::set_scoped_allocator(MyAllocator)` on a function or block.

```kairo
@mem::set_scoped_allocator(ArenaAllocator)
fn process_frame() {
    var a = @create Mesh(vertices)
    var b = @create Texture(pixels)
    // freed wholesale when process_frame returns
}
```

A pointer allocated through a scoped allocator that escapes the allocator's scope is [**Tier N**](/docs/language/tether-proof-model/#the-residual-table). The arena frees the memory at scope end; no smart pointer and no runtime check rescues a pointer to freed arena memory (and across threads, the free races the access). The escape increments the allocation's epoch at the scope close, so the escaping pointer fails C1 by the same machinery as any other dangling pointer. The only fix is restructuring: allocate through the global allocator, or move the scoped boundary outward.

### Freestanding allocator

A scoped-allocator variant for embedded and bare-metal targets, conforming through `static` functions only no indirection, no vtable. The compiler replaces `@create T()` with a direct static call plus placement construction. Tether treats freestanding allocators identically to scoped allocators for lifetime tracking; the difference is a codegen concern.

---

## The Allocator Interface

A type passed to `@mem::set_allocator` or `@mem::set_scoped_allocator`, or used as a freestanding allocator, must satisfy `Allocator`. Conformance is [structural](/docs/language/interfaces/#structural-conformance) and goes through static functions only, so an allocator carries no instance state and no vtable:

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

## Allocators and C++

Exported Kairo classes carry class-specific `operator new` and `operator delete` that always bind to the global allocator, so C++ code can `new` and `delete` Kairo objects directly and a C++ global `operator new` override does not affect them. To route Kairo's own allocations through C++'s allocation path instead, set `core::CxxNewAllocator` as the global allocator. See [Allocators & Ownership](/docs/language/c-cpp-memory/) for the details.

## See also

- [Tether](/docs/language/tether/)
- [Pointers](/docs/language/pointers/)
- [Ownership](/docs/language/ownership/)
- [Allocators & Ownership (C++)](/docs/language/c-cpp-memory/)
- [Unsafe](/docs/language/unsafe/)

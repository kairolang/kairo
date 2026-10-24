# Tether

Tether is a compile-time proof engine. For every pointer dereference in the program, it attempts to prove that the access is safe. When it succeeds, no runtime code is emitted. When it can prove everything except one residual property, it emits the minimal runtime code required to discharge exactly that property and nothing else. When it cannot prove the access safe and no runtime check or code transformation can establish safety, it is a hard compile error.

The system is not a pointer tracker that decides where to insert checks. It is a proof engine that asks one question at every dereference:

> What is the strongest proof I have that this access is safe?

The answer to that question and only the answer determines what code is generated. Tether never asks "should I insert a check here." It asks "which proof obligations remain after static analysis," and emits code for the residual.

Tether operates on [safe pointers](/docs/language/pointers/#safe-pointers-t) (`*T`) only. [Raw pointers](/docs/language/pointers/#raw-pointers-unsafe-t) (`unsafe *T`) carry no obligations and are never analyzed. The programmer owns their correctness.

> [!WARNING]
> Tether is not yet implemented. The current compiler is **Stage 1**; Tether development begins at **Stage 2**. The roadmap:
>
> - **Stage 0** (frozen): bootstrap compiler written in C++. Kept only to bootstrap Stage 1.
> - **Stage 1** (current): self-hosted compiler. No lifetime analysis.
> - **Stage 1.5**: Stage 1 migrated to Kairo's standard library, fully self-hosting.
> - **Stage 2**: compiler rewritten using Kairo's extended feature set. **Tether work begins here.**
>
> This page describes the intended design and target semantics. The analysis is the target, not the current state. A separate formal paper will carry the full proofs; this page states the model and the obligations precisely enough to implement against, but is not itself the proof.

## In this section

- [Proof Model](/docs/language/tether-proof-model/): the dereference obligation, the proof lattice and the residual table.
- [Bounds and Provenance](/docs/language/tether-bounds/): pointer arithmetic, hoisting, provenance and epochs, interior pointers.
- [Ownership and Promotion](/docs/language/tether-promotion/): smart-pointer promotion and stack-pointer escapes.
- [Threading](/docs/language/tether-threading/): strict mode and the race-freedom rule set.
- [Tether Internals](/docs/language/tether-internals/): C/C++ interop, generic code, `.amt` summaries, soundness and testing.

---

## Allocators

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

A pointer allocated through a scoped allocator that escapes the allocator's scope is **Tier N** a hard error in both modes. The arena frees the memory at scope end; no smart pointer and no runtime check rescues a pointer to freed arena memory (and across threads, the free races the access). The escape increments the allocation's epoch at the scope close, so the escaping pointer fails C1 by the same machinery as any other dangling pointer. The only fix is restructuring: allocate through the global allocator, or move the scoped boundary outward.

### Freestanding allocator

A scoped-allocator variant for embedded and bare-metal targets, conforming through `static` functions only no indirection, no vtable. The compiler replaces `@create T()` with a direct static call plus placement construction. Tether treats freestanding allocators identically to scoped allocators for lifetime tracking; the difference is a codegen concern.

---

## Destruction Timing

Where Tether places a value's destruction depends on whether the destructor is observable.

**Trivial destructors** (no observable side effect just memory to reclaim) run at **last use**. Tether places the `@destroy`/`@free` as early as the final use permits, since reclaiming memory after the last use is indistinguishable from reclaiming it at the scope brace:

```kairo
var foo = @create SomeClass()    // trivial destructor
use(foo)
// @destroy foo inserted here
std::println(10)
```

**Non-trivial destructors** (a user-defined `op delete`, or any member with one file close, lock release, flush, disconnect) run at the **end of the owning binding's lexical scope**, in reverse declaration order. Tether does not move these to last use:

```kairo
fn example() {
    var cfg = @create Config(8080)    // side-effecting destructor
    use(cfg)
    std::println(10)
}
// cfg's destructor runs here, at the brace not after use(cfg)
```

This is the "predictable from source" guarantee: any observable destructor side effect fires at the scope brace exactly as written. [`finally`](/docs/language/panic/#finally) blocks, lock guards, and [`NON_TRANSFER`](/docs/language/ownership/#non_transfer-types) scope guards depend on it.

**Shared objects** separate two events. The **refcount decrement** happens at each `Shared` binding's own scope boundary, in reverse declaration order. The **object destructor and deallocation** happen once, when the last live `Shared` reference's scope ends and the count reaches zero which is not necessarily the last-declared binding in any single scope. Reason about shared destruction as "when the final owner goes away," not "reverse declaration order of the binding in front of me." `Weak` scope exit does not touch the count; a `Weak` simply becomes invalid once the target is freed.

## Delete Operation

`delete` in kairo does not free memory. It is a **destruction operation** that runs the [destructor](/docs/language/classes-lifecycle/#destructors---delete-operators) and any side effects, but does not reclaim the allocation. Meaning if the class can be re-constructed with a separate function call, the memory is still valid and can be reused. The `delete` operation is used to explicitly clean up resources without deallocating the memory, which is useful in certain scenarios where you want to manage memory manually or reuse it.

```kairo
class MyClass {
    var data: unsafe *i32 = &null

    fn MyClass(self) = default

    fn init(self) {
        data = unsafe std::alloc<i32>(sizeof i32 * 10) // 10 i32's allocated
    }

    fn op delete(self) {
        if data != &null {
            unsafe std::free(data)
            data = &null
        }
    }
}

var obj = MyClass() // stack allocated the object itself
obj.init() // allocate the buffer data points to
// do something with obj.data
delete obj // runs obj's destructor, which frees the buffer; obj's own storage is not freed
obj.init() // obj is still valid storage and can be re-initialized
```

What `delete` frees is whatever the destructor frees: here the buffer owned by the `data` member. The object `delete` is applied to is not freed; its storage stays valid.

`delete` is supposed to be designed in a idempotent way, meaning that it can be called multiple times on the same object without causing undefined behavior. The first call to `delete` runs the destructor, which releases the resources the members own, while subsequent calls will have no effect since the object is already destroyed. This allows for safe cleanup of resources without worrying about double deletion or dangling pointers.

---

## Copy Elision

For [COPY types](/docs/language/ownership/#copy-types), Tether may emit a move instead of a copy when it proves the source is unused after the transfer **and** the elision is unobservable. Elision means the source's destructor runs at the transfer point instead of at its own scope exit; Tether performs it only when the destructor's observable effects do not depend on that timing trivial destructors, or effects (a `free`, a refcount decrement) that produce identical observable behavior either way.

If the destructor has timing-sensitive side effects a flush, a lock release, a log line Tether does not elide. The copy is preserved and the source is destroyed at its lexical scope exit as written. Elision is silent precisely because it is only applied where it cannot be observed. The programmer neither opts in nor controls it, and it is never applied if the move constructor is deleted.

---

## What Tether Does Not Do

- **Garbage collection.** No tracing, no mark-and-sweep, no runtime collector. Reference counting for `Shared` is the only runtime ownership cost, and it exists only where multiple ownership is required.
- **Runtime borrow checking.** Aliasing is resolved at compile time. Tether does not insert runtime aliasing checks; it inserts bounds, epoch, and (for tainted/nullable residuals) access checks those are clause discharges, not borrow checks.
- **Lifetime annotations.** No `'a`-style parameters, no lifetime polymorphism. Whole-program analysis infers concrete lifetimes from usage.
- **Reference counting everywhere.** Single-owner pointers promote to `Unique` (no refcount); contained lifetimes are not promoted at all. Refcounting appears only under proven multiple ownership.
- **Cross-language analysis.** C++ is opaque beyond the one-level heuristic on a visible body. Across the [FFI boundary](/docs/language/tether-internals/#cc-interop), Tether fails closed (taint inbound, epoch-freeze outbound) rather than guessing.

---

## Summary

The whole system, in one table maps each clause's residual to its response:

| Residual                                         | Response                                     | Tier |
|--------------------------------------------------|----------------------------------------------|------|
| bounds (range)                                   | hoisted/local check, both modes              | R    |
| UAF (provenance intact)                          | epoch compare, both modes                    | R    |
| UAF (provenance lost)                            | hard error                                   | N    |
| nullability                                      | debug check / release error                  | P    |
| ownership escape (heap-promotable)               | debug promote / release error                | P    |
| stack escape (heap-promotable)                   | debug heap-lift / release error              | P    |
| stack escape (non-promotable)                    | hard error                                   | N    |
| scoped-allocator escape                          | hard error                                   | N    |
| opaque-container escape                          | hard error                                   | N    |
| iterator invalidation                            | hard error                                   | N    |
| moved-from use                                   | hard error                                   | N    |
| second writer to shared allocation               | hard error                                   | N    |
| access residual on shared *mutable* allocation   | hard error (strict mode)                     | N    |
| access residual on shared *read-only* allocation | normal Tier-R check                          | R    |
| taint (provenance recoverable)                   | runtime check                                | R    |
| taint (provenance opaque)                        | hard error (demand `unsafe`)                 | N    |

| Type             | Tracked? | Promoted?                 | Escape                                                |
|------------------|----------|---------------------------|-------------------------------------------------------|
| Plain *T (stack) | Yes      | Heap-lift in debug only   | Promotable: debug-lift / release-err; else hard error |
| Plain *T (heap)  | Yes      | Debug: yes / Release: no  | Release: hard error (annotate)                        |
| unsafe *T        | No       | Never                     | Programmer's problem                                  |
| Scoped-alloc ptr | Yes      | Never                     | Always hard error                                     |
| Shared (thread)  | Yes      | n/a                       | One writer, or many `const` readers                   |
| FFI smart ptr    | Yes      | Mapped 1:1                | Type mismatch = error                                 |
| FFI raw ptr      | No       | Never                     | Tainted; requires unsafe/launder                      |

Tether proves every dereference safe statically when it can, and emits nothing. When only a checkable property remains, it emits the minimal check Tier R, the only runtime cost in a release build. When safety needs a program change it transforms in debug and errors in release (Tier P), and when nothing can establish safety it is a hard error in every mode (Tier N).

## See also

- [Ownership](/docs/language/ownership/)
- [Pointers](/docs/language/pointers/)
- [Unsafe](/docs/language/unsafe/)
- [Concurrency](/docs/language/concurrency/)
- [Class Lifecycle](/docs/language/classes-lifecycle/)

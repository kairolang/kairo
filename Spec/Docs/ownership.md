# Ownership

> [!WARNING]
> The ownership model is enforced by [Tether](/docs/language/tether), which is not yet implemented.
> Tether development begins at **Stage 2** of the compiler roadmap. This page describes the
> intended design. See [Tether](/docs/language/tether) for the implementation timeline.

Kairo's ownership model governs how values are created, transferred, borrowed, and destroyed.
It works in conjunction with [Tether](/docs/language/tether) to provide memory safety without lifetime
annotations and without a separate reference type.

The model has two parts: **transfer semantics** (how values move between bindings) and **pointer
aliasing** (how multiple pointers to the same value interact). Transfer semantics are determined
by the type's lifecycle category. Pointer aliasing is tracked by Tether at compile time.

> [!NOTE]
> This page covers *who owns a value and when it dies*. It does not cover the safety of individual
> pointer *accesses* (bounds, use-after-free, null, data races) those are dereference obligations
> discharged by Tether's proof engine, described in [Tether The Dereference Obligation](/docs/language/tether#the-dereference-obligation).
> The distinction matters: ownership and escape violations are resolved by *transforming the program*
> (debug) or a *hard error* (release), never by a runtime check. Access violations may fall back to a
> runtime check. When this page says a violation is "a hard error," it means specifically that no
> ownership transformation can rescue it see [Tether The Residual Table](/docs/language/tether#the-residual-table)
> for the full classification.

---

## Transfer Semantics

Every type in Kairo has a lifecycle category that determines what happens when a value is assigned
to a new binding, passed to a function, or returned. The category is set by which transfer
constructor the type defines. See
[Classes Lifecycle Categories](/docs/language/classes#lifecycle-categories) for the declaration
syntax.

### COPY types

A type with a `@copy` transfer constructor (explicit or implicit) is copyable. Assignment produces
an independent copy both the source and destination are live after the assignment:

```kairo
class Buffer {
    var data: [i32]

    @copy
    fn Buffer(self, const other: Self) = default
}

var a = Buffer()
var b = a          // copy: a and b are independent
b.data.push(42)
a.data.length()       // 0 a is unaffected
```

Tether may **elide a copy into a move** when it proves the source is not used after the transfer and
the elision is unobservable. This is a pure optimization with no observable semantic difference.
Tether does not elide when the destructor has timing-sensitive side effects see
[Tether Copy Elision](/docs/language/tether#copy-elision) for the exact rule.

The programmer does not opt into or control copy elision. Tether applies it when safe.

### MOVE types

A type with a `@move` transfer constructor can only be moved. MOVE types represent unique ownership of a resource. Moving transfers ownership without duplicating the underlying resource, preventing double destruction and expensive deep copies.
Assignment transfers ownership the source is invalidated and cannot be used:

```kairo
class UniqueFile {
    var handle: i32

    @move
    fn UniqueFile(self, other: Self) = default
}

var a = UniqueFile()
var b = a              // move: ownership transfers to b
// a is invalidated any use after this line is a compile error

a.handle               // compile error: a has been moved
b.handle               // ok: b owns the value
```

A type cannot define both `@copy` and `@move` pick one. A type with neither is implicitly COPY
with compiler-generated members.

### NON_TRANSFER types

A type with both `@copy` and `@move` explicitly deleted cannot be assigned, copied, or moved.
The auto-derived `op =` is also `= delete`d as a consequence there is no transfer constructor for
it to be generated from. These are scope-bound values: they live and die in the scope where they
are created:

```kairo
class ScopeLock {
    @copy fn ScopeLock(self, const other: Self) = delete
    @move fn ScopeLock(self, other: Self) = delete
}

var lock = ScopeLock()
// var copy = lock      // compile error: copy deleted
// var moved = lock     // compile error: move deleted
// lock = ScopeLock()   // compile error: op = is deleted
// lock lives until end of scope, then destructor runs
```

> [!NOTE]
> `NON_TRANSFER` types have a specific restriction under threading: they cannot be transfer-captured
> into a spawned task (there is nothing to transfer), and may only be shared read-only by address.
> See [Tether Threading](/docs/language/tether#threading).

### Structs

Structs have value semantics. Assignment copies their object representation byte-for-byte via `memcpy`. Because structs cannot define constructors, destructors, or transfer constructors, this copy is always valid.

```kairo
struct Point { var x: f64; var y: f64 }

var a = Point { x: 1.0, y: 2.0 }
var b = a      // memcpy always, unconditionally
b.x = 9.0
a.x            // 1.0 independent copy
```

See [Structures](/docs/language/structures#copy-semantics).

---

## Function Parameters

Function parameters follow the same transfer rules as assignment. Passing a COPY type copies it.
Passing a MOVE type moves it the caller cannot use the value after the call:

```kairo
fn consume(file: UniqueFile) {
    // file is owned by consume
}

var f = UniqueFile()
consume(f)
// f is invalidated moved into consume
f.handle       // compile error: f has been moved
```

```kairo
fn inspect(buf: Buffer) {
    // buf is an independent copy
}

var b = Buffer()
inspect(b)
b.data.length()   // ok: b is still live, inspect got a copy
```

To let a callee write to the caller's object, or to take ownership of a generic argument, use the
`@inout` and `@move` parameter modes. See [Parameter passing modes](/docs/language/functions#parameter-passing-modes).

### Last-use move optimization

For MOVE types, Tether detects when a value is passed to a function and never used again. In this
case, the value is moved rather than requiring explicit annotation:

```kairo
var m = Moveable()
foo(m)          // m is moved Tether sees m is not referenced after this line
// m is invalidated from here
```

This only applies when the value is genuinely unused after the call. If any subsequent code
references the value, it is a compile error (MOVE types cannot be copied).

### Pass-by-pointer optimization

When a function takes a parameter by value and the type is larger than a pointer (8 bytes on
64-bit), the compiler may silently pass a pointer instead of copying. This is a **codegen
optimization only** the source-level semantics are always by-value. The optimization applies
only when Tether can prove the by-value semantics are preserved for the duration of the call:

- The parameter is not aliased *and mutated* through any other live pointer while the call is in
  progress i.e. Tether proves no write reaches the same allocation during the call.
- The parameter is not modified inside the callee (or the function takes it as `const`).
- The parameter is not stored, returned, or captured.
- The function is not `async`.

The first condition is stronger than "no other pointer exists." Kairo permits arbitrary mutable
aliasing in single-threaded code (see [Pointer Aliasing](#pointer-aliasing)), so Tether cannot rely on
the absence of aliases it must prove that no *write* through an alias is observable during the
call. If it cannot prove this, the parameter is copied as written. The programmer does not control
this optimization and cannot observe it.

---

## Pointer Aliasing

Kairo allows multiple pointers to the same value. There is no Rust-style exclusivity rule (one
mutable xor many immutable) **in single-threaded code**. Multiple `*T` to the same location is
legal, and writing through one pointer is visible through all others:

```kairo
var x = 42
var p: *i32 = &x
var q: *i32 = &x
*p = 100
std::println(*q)   // 100 defined behavior
```

> [!IMPORTANT]
> This freedom is single-threaded only. The moment an allocation is shared across a thread boundary
> (captured into a `spawn`/`thread`), Tether switches to a stricter rule: one writer, or many readers,
> never both. Arbitrary mutable aliasing is permitted within one thread because a single-threaded
> race is impossible; across threads it is undefined behavior that no runtime check can rule out, so
> the rule tightens exactly at the boundary. See [Tether Threading](/docs/language/tether#threading).

This applies uniformly regardless of `const`:

```kairo
var x = 42
var p: *i32 = &x
var q: *const i32 = &x
*p = 100
std::println(*q)   // 100 *const prevents mutation through q, not through p
```

`const` is a **semantic check on the binding**, not an aliasing constraint. Of the
[two questions a pointer declaration answers](/docs/language/variables#the-const-binding-rule),
"can I change the pointee?" is asked about one pointer only. `*const T` prevents
the holder from mutating through that pointer. It does not prevent other pointers from mutating
the same value. Tether does not change behavior based on `const` qualifiers it tracks provenance
and lifetime independently of mutability.

### What Tether enforces

Tether does not restrict aliasing patterns in single-threaded code. What it does enforce:

**Provenance validity.** A pointer must refer to memory that is still live. Using a pointer after
its target has been destroyed is a hard error. This is clause C1 of the dereference obligation,
discharged by epoch tracking Tether proves the allocation has not been freed or relocated since the
pointer was derived:

```kairo
var p: *i32
{
    var x = 42
    p = &x
}
*p = 10    // hard error: x is destroyed (epoch incremented), p is dangling
```

When provenance is intact but the epoch cannot be proven equal statically, this access falls back
to a runtime epoch check rather than a hard error see
[Tether Provenance and Epochs](/docs/language/tether#provenance-and-epochs). It is a hard error only when
provenance is lost entirely.

**Iterator invalidation.** A pointer into a container's buffer is invalidated by operations that
may reallocate the buffer:

```kairo
var v: [i32] = [1, 2, 3]
var p: *i32 = &v[0]
v.push(4)           // may reallocate v's internal buffer
std::println(*p)    // hard error: p's provenance is invalidated by push
```

Tether detects this through `.amt` summaries: `push`'s summary records that it may reallocate the
backing buffer, so any live pointer into that buffer is flagged at the call site. **Invalidation is
a hard error even when Tether can trace the reallocation** it is not a runtime-check fallback. The
realloc is provable statically, re-validating every live pointer across every potentially-reallocating
call would be expensive, and a use-after-realloc is almost always a real bug, so Tether errors rather
than checks. Where the buffer is mutated through a path Tether cannot trace (an opaque container, a raw
FFI call), Tether also errors rather than allowing an unprovable access. See
[Tether Analysis scope](/docs/language/tether#the-dereference-obligation).

**Stack escape.** A pointer to a stack-allocated value cannot outlive the value. What happens when
it tries depends on whether the value is **heap-promotable**:

```kairo
fn make() -> *i32 {
    var x = 42
    return &x
    // debug: Tether rewrites `var x = 42` to a heap allocation and promotes the
    //        escaping pointer (Unique)
    // release: hard error a heap allocation in a release binary must be visible
    //          in the source, so Tether shows the fix instead of inserting it silently
}
```

A stack escape of a heap-promotable value is **debug-transformable / release-error** Tether can lift
`x` to the heap, which turns the escape into a legal ownership transfer. A stack escape with *no
value to lift* (a borrow with no owner, an escape into an opaque sink where Tether cannot establish the
heap-allocation pattern) is a hard error in both modes there is nothing to transform. This is the
split the [Tether Stack Pointers](/docs/language/tether#stack-pointers) section details in full. Either
way, the fix in release is to allocate explicitly or restructure.

> [!NOTE]
> **Data-race detection across threads** is enforced by Tether's strict threading mode. When an
> allocation is shared across a `spawn`/`thread` boundary, Tether requires a single writer (or
> read-only sharing) and treats a second writer, or any unsynchronized write+read, as a hard error.
> The synchronization primitives that discharge these obligations depend on Kairo's concurrency
> runtime, which is not yet finalized the analysis shape is fixed, the runtime seam is not. See
> [Tether Threading](/docs/language/tether#threading) and [Concurrency](/docs/language/concurrency).

### What Tether does not enforce

Tether does not prevent multiple mutable pointers to the same value in single-threaded code. This
is intentional many valid patterns require mutable aliasing (parent/child pointers, graph
structures, cache-and-source patterns). The tradeoff: Kairo allows more programs than Rust at
the cost of not statically preventing all aliasing bugs. Tether catches the ones that are provably
wrong (dangling, invalidation, and across a thread boundary races) and lets the rest through.

### noalias optimization

When Tether proves that two pointers do not alias (point to different allocations or non-overlapping
regions), it attaches `noalias` metadata to the LLVM IR. This enables the backend optimizer to
perform more aggressive transformations (load/store reordering, vectorization) without the
programmer writing anything. This is invisible the source code does not change, and the
behavior is identical with or without the tag.

---

## Smart Pointer Promotion and Aliasing

When Tether promotes a heap pointer to a smart pointer (in debug mode), the aliasing pattern
determines which smart pointer type is chosen. In release, the same analysis produces a hard error
naming the type to annotate Tether does not silently change pointer types in a release binary. See
[Tether Ownership and Promotion](/docs/language/tether#ownership-and-promotion).

```kairo
// Single owner, no aliasing -> Unique
var cfg = @create Config(8080)
return cfg
// Tether: cfg has one owner -> Unique
```

```kairo
// Aliased, both pointers escape -> Shared
var cfg = @create Config(8080)
server_a.config = cfg
server_b.config = cfg
// Tether: cfg is aliased across two live bindings -> Shared
```

```kairo
// Aliased, but the alias dies before escape -> Unique
var cfg = @create Config(8080)
{
    var tmp: *Config = cfg
    validate(tmp)
}
// tmp is dead cfg has single ownership at this point
return cfg
// Tether: alias was short-lived, cfg is sole owner -> Unique
```

The promotion trigger is not "multiple pointers exist" but "multiple pointers exist AND the
aliasing pattern requires shared ownership for safety." A short-lived alias that dies before the
owner escapes does not force `Shared`.

Because Tether is whole-program, the cases where promotion is actually needed are narrow. Most
pointers have fully contained lifetimes and require no promotion at all.

See [Tether Promotion Decision](/docs/language/tether#ownership-and-promotion) for the full decision tree.

---

## Closure Captures

Closures capture variables from their enclosing scope. The capture mode determines the ownership
relationship between the closure and the captured variable. Kairo has no reference types, so a
closure holds either its own value or a pointer.

### Default capture (by value)

With no capture list, a closure captures every referenced variable by value, using its type's
transfer semantics: COPY types are copied, MOVE types are moved. Captures happen at closure
creation time, not at invocation:

```kairo
var buf = Buffer()       // COPY type
var file = UniqueFile()  // MOVE type

var closure = fn () {
    buf.data.push(1)     // operates on the closure's copy
    file.close()         // operates on the moved-in file
}

buf.data.length()        // ok: buf was copied, original is still live
file.handle              // compile error: file was moved into the closure
```

### Capture by pointer (`|*|`)

`|*|` captures all referenced variables by pointer. The closure holds `*T` to each captured
variable and reaches it through explicit dereference. Mutations through the pointer affect the
original:

```kairo
var count = 0

var inc = fn ()|*| {
    *count += 1    // modifies the original count through a pointer
}

inc()
inc()
count   // 2
```

Tether tracks pointer captures the same way it tracks any other pointer. If the closure escapes
and the captured variable is stack-allocated, the heap-promotable / non-promotable split applies
exactly as it does for any stack escape (see [Stack escape](#what-tether-enforces) above): a
promotable value is heap-lifted in debug and a hard error in release; a non-promotable one is a
hard error in both modes:

```kairo
fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn ()|*x| -> i32 { return *x }
    // debug: x is heap-lifted and the capture promoted
    // release: hard error, capture by value or heap-allocate explicitly
}
```

Capture by value sidesteps the escape entirely: the closure owns its own copy with no lifetime
dependency on the enclosing frame:

```kairo
fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn () -> i32 { return x }
    // ok: x is copied into the closure, no lifetime dependency
}
```

> [!NOTE]
> When a closure is captured into a spawned task, pointer captures fall under Tether's threading rules:
> a `const *` (read-only) capture shares the allocation read-only across the boundary; a mutating
> `*` capture makes the allocation a shared *mutable* allocation and triggers the single-writer
> analysis. See [Tether Threading](/docs/language/tether#threading).

### Per-variable capture

Name variables in the capture list to choose a mode for each. Unqualified names are captured by
value, `*`-prefixed names by pointer, and `const *`-prefixed names by const pointer:

```kairo
var a = Buffer()    // COPY
var b = 0

var closure = fn ()|a, *b| {
    a.data.push(1)   // closure's own copy of a
    *b += 1          // modifies the original b through a pointer
}
```

See [Closures](/docs/language/closures) for the full capture syntax.

---

## Destruction Order

Values are destroyed at the end of their enclosing scope in **reverse declaration order**. This
applies to stack-allocated, heap-allocated, and smart-pointer-promoted values alike:

```kairo
fn example() {
    var a = Resource("first")
    var b = Resource("second")
    var c = Resource("third")
}
// destruction order: c, b, a
```

For smart pointers promoted by Tether:

- `std::Unique<T>`: the object destructor runs at the end of the owning binding's lexical scope,
  in reverse declaration order.
- `std::Shared<T>`: each binding decrements the reference count at its own scope boundary in
  reverse declaration order; the *object* destructor and deallocation run once, when the last
  `Shared` reference's scope ends. The decrement order is lexical and deterministic; the object
  destructor fires at the final owner, which is not necessarily the last-declared binding in any
  single scope. See [Tether Destruction Timing](/docs/language/tether#destruction-timing).
- `std::Weak<*T>`: invalidated at scope exit. Does not affect the reference count.

There is no drop-at-last-use optimization for observable destructors. Destruction of a value whose
destructor has side effects (file close, lock release, flush) is tied to lexical scope, so the
effect is predictable from reading the source. A value whose destructor is trivial may be reclaimed
at last use, since that is unobservable see [Tether Destruction Timing](/docs/language/tether#destruction-timing)
for the trivial / non-trivial split.

---

## Moved-From State

After a value is moved, the source binding is **invalidated**. Any use of a moved-from binding
is a compile error there is no "valid but unspecified" state like C++:

```kairo
var a = UniqueFile()
var b = a              // move

a.handle               // compile error: a has been moved
a = UniqueFile()       // ok: a can be reassigned to a new value
a.handle               // ok: a is live again
```

A moved-from binding can be reassigned. After reassignment, it is live again with the new value.
But between the move and the reassignment, any access is a hard error.

This is enforced by Tether in both debug and release builds, and it is a **static** determination, not
a runtime check there is no runtime fallback for a moved-from access the way there is for an
unprovable bounds access. A use-after-move is a logic error the compiler proves at compile time, not
a safety property discharged at runtime; the compiler statically tracks which bindings are live and
which have been moved.

---

## Summary

| Type category | Assignment | Source after | Function param        |
|---------------|------------|--------------|-----------------------|
| COPY          | Copy       | Live         | Copy (caller keeps)   |
| MOVE          | Move       | Invalidated  | Move (caller loses)   |
| NON_TRANSFER  | Error      | N/A          | Error                 |
| Struct        | memcpy     | Live         | memcpy (caller keeps) |

Escape and ownership violations resolve by *transforming the program* in debug (heap-lift, smart
pointer promotion) and a *hard error with the fix* in release. They are never runtime checks that
is reserved for access obligations like bounds. See
[Tether The Residual Table](/docs/language/tether#the-residual-table).

```kairo
// COPY: both sides live after transfer
var a = Copyable()
var b = a              // copy
a.method()             // ok
b.method()             // ok

// MOVE: source invalidated after transfer
var x = Moveable()
var y = x              // move
// x.method()          // compile error
y.method()             // ok

// Pointer aliasing (single-threaded): allowed, Tether checks provenance
var val = 42
var p = &val
var q = &val
*p = 100
std::println(*q)       // 100

// Closure capture by value (default)
var m = Moveable()
var f = fn () { m.use() }
// m is moved into f

// Closure capture by pointer
var n = 0
var g = fn ()|*| { *n += 1 }
g()
// n is 1
```
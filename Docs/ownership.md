# Ownership

> [!WARNING]
> The ownership model is enforced by [Tether](/docs/language/tether/), which is not yet implemented. Tether development begins at **Stage 2** of the compiler roadmap. This page describes the intended design. See [Tether](/docs/language/tether/) for the implementation timeline.

Kairo's ownership model governs how values are created, transferred, borrowed, and destroyed. It works in conjunction with [Tether](/docs/language/tether/) to provide memory safety without lifetime annotations and without a separate reference type.

The model has two parts: **transfer semantics** (how values move between bindings) and **pointer aliasing** (how multiple pointers to the same value interact). Transfer semantics are determined by the type's lifecycle category. Pointer aliasing is tracked by Tether at compile time.

> [!NOTE]
> This page covers *who owns a value and when it dies*. It does not cover the safety of individual pointer *accesses* (bounds, use-after-free, null, data races) those are dereference obligations discharged by Tether's proof engine, described in [Tether The Dereference Obligation](/docs/language/tether-proof-model/#the-dereference-obligation). The distinction matters: ownership and escape violations are resolved by *transforming the program* (debug) or a *hard error* (release), never by a runtime check. Access violations may fall back to a runtime check. When this page says a violation is "a hard error," it means specifically that no ownership transformation can rescue it see [Tether The Residual Table](/docs/language/tether-proof-model/#the-residual-table) for the full classification.

---

## Transfer Semantics

Every type in Kairo has a lifecycle category that determines what happens when a value is assigned to a new binding, passed to a function, or returned. The category is set by which transfer constructor the type defines. See [Classes Lifecycle Categories](/docs/language/classes-lifecycle/#lifecycle-categories) for the declaration syntax.

### COPY types

A type with a `@copy` transfer constructor (explicit or implicit) is copyable. Assignment produces an independent copy both the source and destination are live after the assignment:

```kairo
class Buffer {
    var data: [i32]

    fn Buffer(self) = default

    @copy
    fn Buffer(self, const other: Self) = default
}

var a = Buffer()
var b = a          // copy: a and b are independent
b.data.push(42)
a.data.size()       // 0 a is unaffected
```

Tether may **elide a copy into a move** when it proves the source is not used after the transfer and the elision is unobservable. This is a pure optimization with no observable semantic difference. Tether does not elide when the destructor has timing-sensitive side effects see [Tether Copy Elision](/docs/language/tether/#copy-elision) for the exact rule.

The programmer does not opt into or control copy elision. Tether applies it when safe.

### MOVE types

A type with a `@move` transfer constructor can only be moved. MOVE types represent unique ownership of a resource. Moving transfers ownership without duplicating the underlying resource, preventing double destruction and expensive deep copies. Assignment transfers ownership the source is invalidated and cannot be used:

```kairo
class UniqueFile {
    var handle: i32

    fn UniqueFile(self) = default

    @move
    fn UniqueFile(self, other: Self) = default
}

var a = UniqueFile()
var b = a              // move: ownership transfers to b
// a is invalidated any use after this line is a compile error

a.handle               // compile error: a has been moved
b.handle               // ok: b owns the value
```

A type cannot define both `@copy` and `@move` (unless both are `= delete`) pick one. A type with neither takes the weakest category its bases and fields allow: COPY if all of them are, MOVE if any is move-only, NON_TRANSFER if any cannot be transferred. Its members are compiler-generated to match.

### NON_TRANSFER types

A type with a deleted transfer constructor (`@copy ... = delete`, `@move ... = delete`, or both) cannot be assigned, copied, or moved. The auto-derived `op =` is also `= delete`d as a consequence there is no transfer constructor for it to be generated from. These are scope-bound values: they live and die in the scope where they are created:

```kairo
class ScopeLock {
    fn ScopeLock(self) = default

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
> `NON_TRANSFER` types have a specific restriction under threading: they cannot be transfer-captured into a spawned task (there is nothing to transfer), and may only be shared read-only by address. See [Tether Threading](/docs/language/tether-threading/#threading).

### Structs

Structs have value semantics. Assignment copies their object representation byte-for-byte via `memcpy`. Because structs cannot define constructors, destructors, or transfer constructors, this copy is always valid.

```kairo
struct Point { var x: f64; var y: f64 }

var a = Point { x: 1.0, y: 2.0 }
var b = a      // memcpy always, unconditionally
b.x = 9.0
a.x            // 1.0 independent copy
```

See [Structures](/docs/language/structures/#copy-semantics).

---

## Function Parameters

Function parameters follow the same transfer rules as assignment. Passing a COPY type copies it. Passing a MOVE type moves it the caller cannot use the value after the call:

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
b.data.size()   // ok: b is still live, inspect got a copy
```

To let a callee write to the caller's object, or to take ownership of a generic argument, use the `@inout` and `@move` parameter modes. See [Parameter passing modes](/docs/language/functions-parameter-modes/#parameter-passing-modes).

### Last-use move optimization

For MOVE types, Tether detects when a value is passed to a function and never used again. In this case, the value is moved rather than requiring explicit annotation:

```kairo
var m = UniqueFile()
foo(m)          // m is moved Tether sees m is not referenced after this line
// m is invalidated from here
```

This only applies when the value is genuinely unused after the call. If any subsequent code references the value, it is a compile error (MOVE types cannot be copied).

### Pass-by-pointer optimization

When a function takes a parameter by value and the type is larger than a pointer (8 bytes on 64-bit), the compiler may silently pass a pointer instead of copying. This is a **codegen optimization only** the source-level semantics are always by-value. The optimization applies only when Tether can prove the by-value semantics are preserved for the duration of the call:

- The parameter is not aliased *and mutated* through any other live pointer while the call is in progress i.e. Tether proves no write reaches the same allocation during the call.
- The parameter is not modified inside the callee (or the function takes it as `const`).
- The parameter is not stored, returned, or captured.
- The function is not [`async`](/docs/language/concurrency/#asyncawait).

The first condition is stronger than "no other pointer exists." Kairo permits arbitrary mutable aliasing in single-threaded code (see [Pointer Aliasing](#pointer-aliasing)), so Tether cannot rely on the absence of aliases it must prove that no *write* through an alias is observable during the call. If it cannot prove this, the parameter is copied as written. The programmer does not control this optimization and cannot observe it.

---

## Pointer Aliasing

Kairo allows multiple pointers to the same value. There is no Rust-style exclusivity rule (one mutable xor many immutable) **in single-threaded code**. Multiple `*T` to the same location is legal, and writing through one pointer is visible through all others:

```kairo
var x = 42
var p: *i32 = &x
var q: *i32 = &x
*p = 100
std::io::println(*q)   // 100 defined behavior
```

> [!IMPORTANT]
> This freedom is single-threaded only. The moment an allocation is shared across a thread boundary (captured into a [`spawn`](/docs/language/concurrency/#spawn)ed task), Tether switches to a stricter rule: one writer, or many readers, never both. Arbitrary mutable aliasing is permitted within one thread because a single-threaded race is impossible; across threads it is undefined behavior that no runtime check can rule out, so the rule tightens exactly at the boundary. See [Tether Threading](/docs/language/tether-threading/#threading).

This applies uniformly regardless of `const`:

```kairo
var x = 42
var p: *i32 = &x
var q: *const i32 = &x
*p = 100
std::io::println(*q)   // 100 *const prevents mutation through q, not through p
```

`const` is a **semantic check on the binding**, not an aliasing constraint. Of the [two questions a pointer declaration answers](/docs/language/variables/#the-const-binding-rule), "can I change the pointee?" is asked about one pointer only. `*const T` prevents the holder from mutating through that pointer. It does not prevent other pointers from mutating the same value. Tether does not change behavior based on `const` qualifiers it tracks provenance and lifetime independently of mutability.

### What Tether enforces

Tether does not restrict aliasing patterns in single-threaded code. What it does enforce:

**Provenance validity.** A pointer must refer to memory that is still live. Using a pointer after its target has been destroyed is a hard error. This is clause C1 of the [dereference obligation](/docs/language/tether-proof-model/#the-dereference-obligation), discharged by epoch tracking Tether proves the allocation has not been freed or relocated since the pointer was derived:

```kairo
var p: *i32
{
    var x = 42
    p = &x
}
*p = 10    // hard error: x is destroyed (epoch incremented), p is dangling
```

When provenance is intact but the epoch cannot be proven equal statically, this access falls back to a runtime epoch check rather than a hard error see [Tether Provenance and Epochs](/docs/language/tether-bounds/#provenance-and-epochs). It is a hard error only when provenance is lost entirely.

**Iterator invalidation.** A pointer into a container's buffer is invalidated by operations that may reallocate the buffer:

```kairo
var v: [i32] = [1, 2, 3]
var p: *i32 = &v[0]
v.push(4)           // may reallocate v's internal buffer
std::io::println(*p)    // hard error: p's provenance is invalidated by push
```

Tether detects this through [`.amt` summaries](/docs/language/tether-internals/#amt-summaries): `push`'s summary records that it may reallocate the backing buffer, so any live pointer into that buffer is flagged at the call site. **Invalidation is a hard error even when Tether can trace the reallocation** it is not a runtime-check fallback. The realloc is provable statically, re-validating every live pointer across every potentially-reallocating call would be expensive, and a use-after-realloc is almost always a real bug, so Tether errors rather than checks. Where the buffer is mutated through a path Tether cannot trace (an opaque container, a raw FFI call), Tether also errors rather than allowing an unprovable access. See [Tether Analysis scope](/docs/language/tether-proof-model/#the-dereference-obligation).

**Stack escape.** A pointer to a stack-allocated value cannot outlive the value. What happens when it tries depends on whether the value is **heap-promotable**:

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

A stack escape of a heap-promotable value is **debug-transformable / release-error** Tether can lift `x` to the heap, which turns the escape into a legal ownership transfer. A stack escape with *no value to lift* (a borrow with no owner, an escape into an opaque sink where Tether cannot establish the heap-allocation pattern) is a hard error in both modes there is nothing to transform. This is the split the [Tether Stack Pointers](/docs/language/tether-promotion/#stack-pointers) section details in full. Either way, the fix in release is to allocate explicitly or restructure.

> [!NOTE]
> **Data-race detection across threads** is enforced by Tether's strict threading mode. When an allocation is shared across a `spawn` boundary, Tether requires a single writer (or read-only sharing) and treats a second writer, or any unsynchronized write+read, as a hard error. The synchronization primitives that discharge these obligations depend on Kairo's concurrency runtime, which is not yet finalized the analysis shape is fixed, the runtime seam is not. See [Tether Threading](/docs/language/tether-threading/#threading) and [Concurrency](/docs/language/concurrency/).

### What Tether does not enforce

Tether does not prevent multiple mutable pointers to the same value in single-threaded code. This is intentional many valid patterns require mutable aliasing (parent/child pointers, graph structures, cache-and-source patterns). The tradeoff: Kairo allows more programs than Rust at the cost of not statically preventing all aliasing bugs. Tether catches the ones that are provably wrong (dangling, invalidation, and across a thread boundary races) and lets the rest through.

### noalias optimization

When Tether proves that two pointers do not alias (point to different allocations or non-overlapping regions), it attaches `noalias` metadata to the LLVM IR. This enables the backend optimizer to perform more aggressive transformations (load/store reordering, vectorization) without the programmer writing anything. This is invisible the source code does not change, and the behavior is identical with or without the tag.

---

## Smart Pointer Promotion and Aliasing

When Tether promotes a heap pointer to a [smart pointer](/docs/language/pointers/#smart-pointer-promotion) (in debug mode), the aliasing pattern determines which smart pointer type is chosen. In release, the same analysis produces a hard error naming the type to annotate Tether does not silently change pointer types in a release binary. See [Tether Ownership and Promotion](/docs/language/tether-promotion/#ownership-and-promotion).

```kairo
// Single owner, no aliasing -> Unique
var *cfg = @create Config(8080)
return cfg
// Tether: cfg has one owner -> Unique
```

```kairo
// Aliased, both pointers escape -> Shared
var *cfg = @create Config(8080)
server_a.config = cfg
server_b.config = cfg
// Tether: cfg is aliased across two live bindings -> Shared
```

```kairo
// Aliased, but the alias dies before escape -> Unique
var *cfg = @create Config(8080)
{
    var tmp: *Config = cfg
    validate(tmp)
}
// tmp is dead cfg has single ownership at this point
return cfg
// Tether: alias was short-lived, cfg is sole owner -> Unique
```

The promotion trigger is not "multiple pointers exist" but "multiple pointers exist AND the aliasing pattern requires shared ownership for safety." A short-lived alias that dies before the owner escapes does not force `Shared`.

Because Tether is whole-program, the cases where promotion is actually needed are narrow. Most pointers have fully contained lifetimes and require no promotion at all.

See [Tether Promotion Decision](/docs/language/tether-promotion/#ownership-and-promotion) for the full decision tree.

---

## Closure Captures

[Closures](/docs/language/closures/#capture-modes) capture variables from their enclosing scope. The capture mode determines the ownership relationship between the closure and the captured variable. Kairo has no reference types, so a closure holds either its own value or a pointer.

### Default capture (by value)

With no capture list, a closure captures every referenced variable by value, using its type's transfer semantics: COPY types are copied, MOVE types are moved. Captures happen at closure creation time, not at invocation:

```kairo
var buf = Buffer()       // COPY type
var file = UniqueFile()  // MOVE type

var closure = fn () {
    buf.data.push(1)     // operates on the closure's copy
    file.close()         // operates on the moved-in file
}

buf.data.size()        // ok: buf was copied, original is still live
file.handle              // compile error: file was moved into the closure
```

### Capture by pointer (`|*|`)

`|*|` captures all referenced variables by pointer. The closure holds `*T` to each captured variable and reaches it through explicit dereference. Mutations through the pointer affect the original:

```kairo
var count = 0

var inc = fn ()|*| {
    *count += 1    // modifies the original count through a pointer
}

inc()
inc()
count   // 2
```

Tether tracks pointer captures the same way it tracks any other pointer. If the closure escapes and the captured variable is stack-allocated, the heap-promotable / non-promotable split applies exactly as it does for any stack escape (see [Stack escape](#what-tether-enforces) above): a promotable value is heap-lifted in debug and a hard error in release; a non-promotable one is a hard error in both modes:

```kairo
fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn ()|*x| -> i32 { return *x }
    // debug: x is heap-lifted and the capture promoted
    // release: hard error, capture by value or heap-allocate explicitly
}
```

Capture by value sidesteps the escape entirely: the closure owns its own copy with no lifetime dependency on the enclosing frame:

```kairo
fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn () -> i32 { return x }
    // ok: x is copied into the closure, no lifetime dependency
}
```

> [!NOTE]
> When a closure is captured into a spawned task, pointer captures fall under Tether's threading rules: a `const *` (read-only) capture shares the allocation read-only across the boundary; a mutating `*` capture makes the allocation a shared *mutable* allocation and triggers the single-writer analysis. See [Tether Threading](/docs/language/tether-threading/#threading).

### Per-variable capture

Name variables in the capture list to choose a mode for each. Unqualified names are captured by value, `*`-prefixed names by pointer, and `const *`-prefixed names by const pointer:

```kairo
var a = Buffer()    // COPY
var b = 0

var closure = fn ()|a, *b| {
    a.data.push(1)   // closure's own copy of a
    *b += 1          // modifies the original b through a pointer
}
```

See [Closures](/docs/language/closures/) for the full capture syntax.

---

## Destruction Order

Values are destroyed at the end of their enclosing scope in **reverse declaration order**. This applies to stack-allocated, heap-allocated, and smart-pointer-promoted values alike:

```kairo
fn example() {
    var a = Resource("first")
    var b = Resource("second")
    var c = Resource("third")
}
// destruction order: c, b, a
```

For smart pointers promoted by Tether:

- `std::Unique<T>`: the object destructor runs at the end of the owning binding's lexical scope, in reverse declaration order.
- `std::Shared<T>`: each binding decrements the reference count at its own scope boundary in reverse declaration order; the *object* destructor and deallocation run once, when the last `Shared` reference's scope ends. The decrement order is lexical and deterministic; the object destructor fires at the final owner, which is not necessarily the last-declared binding in any single scope. See [Tether Destruction Timing](/docs/language/tether/#destruction-timing).
- `std::Weak<*T>`: invalidated at scope exit. Does not affect the reference count.

There is no drop-at-last-use optimization for observable destructors. Destruction of a value whose destructor has side effects (file close, lock release, flush) is tied to lexical scope, so the effect is predictable from reading the source. A value whose destructor is trivial may be reclaimed at last use, since that is unobservable see [Tether Destruction Timing](/docs/language/tether/#destruction-timing) for the trivial / non-trivial split.

---

## Moved-From State

After a value is moved, the source binding is **invalidated**. Any use of a moved-from binding is a compile error there is no "valid but unspecified" state like C++:

```kairo
var a = UniqueFile()
var b = a              // move

a.handle               // compile error: a has been moved
a = UniqueFile()       // ok: a can be reassigned to a new value
a.handle               // ok: a is live again
```

A moved-from binding can be reassigned. After reassignment, it is live again with the new value. But between the move and the reassignment, any access is a hard error.

### Moving a part

A move does not have to take a whole variable. Moving a field leaves that field moved-from and the rest of the value usable. Using the moved field, or the value as a whole, is an error until the field is assigned again. The same rule covers a field of `self` and a field reached through a pointer:

```kairo
class Pair {
    pub var a: UniqueFile
    pub var b: UniqueFile
}

var p = Pair()
var x = p.a            // move: p.a is moved-from
p.b.handle             // ok: p.b is untouched
p.a.handle             // compile error: p.a has been moved
consume(p)             // compile error: p is used while p.a is gone
p.a = UniqueFile()     // ok: p is whole again

fn take(q: *Pair) {
    var y = q->a       // move: q->a is moved-from
    q->b.handle        // ok
    q->a.handle        // compile error: q->a has been moved
}
```

Moving an element out of an array or a container leaves the whole container moved-from, because the compiler does not track which index was taken:

```kairo
var files: [UniqueFile; 2]
var first = files[0]   // move: files is moved-from
files[1].handle        // compile error: files is used after files[0] was moved out of it
```

To take one element and keep the rest, use a method of the container that leaves it valid.

A function that returns while a part of `self`, of an `@inout` parameter or of what a parameter points at is still moved-from leaves that part moved-from in the caller's object. Nothing is written in the signature: the compiler reads it from the function's body.

```kairo
class Holder {
    pub var p: Pair

    fn take_a(self) -> UniqueFile { return self.p.a }   // leaves self.p.a moved-from

    fn swap_a(self, f: UniqueFile) -> UniqueFile {
        var old = self.p.a
        self.p.a = f                                    // assigned again: leaves nothing
        return old
    }
}

var h = Holder()
var a = h.take_a()     // h.p.a is moved-from
h.p.b.handle           // ok
h.p.a.handle           // compile error: h.p.a has been moved, by the call to take_a
h.p.a = UniqueFile()   // ok: h is whole again
```

A function that moves its argument only on one outcome leaves it moved-from only on that outcome. Three outcomes are told apart: returning `true` or `false`, returning `null` or a value, and panicking or returning.

```kairo
fn push(self, @inout v: Task) -> bool {
    if self.full() { return false }   // v untouched
    self.slot = v                     // v moved
    return true
}

if q.push(&t) {
    // t is moved-from here
} else {
    t.run()                           // ok: push returned false, t is whole
}

while !q.push(&t) { wait() }          // t is whole in the body, moved-from after the loop
```

The caller sees the outcome when the call is itself the condition of an `if` or a loop, alone or under `!`, `&&`, `||`, `?`, `== null` or `!= null`, and in the `catch` arms of a `try` for a panic. A local initialised from the call (`var ok = q.push(&t)`) carries the outcome too: until it is tested `t` counts as moved, and a test of `ok` marks each branch as a test of the call would, as long as `ok` is not used any other way and `t` is not moved again in between. A function that returns the call's result (`return q.push(&v)`, or `return ok`) moves its argument on the same outcome. A part moved only when the function panics with one type is moved-from only in a `catch` arm that catches that type, or a bare `catch`. Anywhere else, such as a result passed to another function, the argument counts as moved.

```kairo
var ok = q.push(&t)
if !ok { t.run() }                            // ok: push returned false
try { give(&t) } catch e: Other { t.run() }   // ok: give moves t only when it panics with Full
```

A function declared in Kairo and implemented in C or C++ has no body to read, so the compiler assumes the worst: after the call, a move-only value it could have moved out of is moved-from. That is a non-const receiver, an `@inout` argument, and what a pointer to non-const points at. Declare the parameter `const`, or take a pointer to const, when the function only reads; declare it `@move` when the function takes the value. The error's note at the declaration says the same.

```kairo
fn native_fill(@inout h: Holder)        // implemented in C++
fn native_len(const h: Holder) -> usize // implemented in C++

var h = Holder()
native_len(h)      // ok: const, h is untouched
native_fill(&h)    // h is taken to be moved-from
h.p.a.handle       // compile error: h is used after being moved
h = Holder()       // ok again
```

> [!NOTE]
> The compiler reads the body of the function that is called, wherever it is defined: a method declared in its class and defined out of line, or a function in another file, is read the same way. These are not looked into yet: a call through an interface, a virtual method, a function pointer or a stored closure; a user-defined operator; a call to a C or C++ function whose body the compiler cannot read (when it can, a move out of a `T&` or `T*` argument is seen: see [Calling C and C++](/docs/language/c-cpp-calling/#moves-out-of-a-t-or-t)); a field whose type is a generic parameter; and, of two files that import each other, the one checked first. A second pointer to the same object and indexing a raw pointer (`p[i]`) are not tracked.

This is enforced by Tether in both debug and release builds, and it is a **static** determination, not a runtime check there is no runtime fallback for a moved-from access the way there is for an unprovable bounds access. A use-after-move is a logic error the compiler proves at compile time, not a safety property discharged at runtime; the compiler statically tracks which bindings are live and which have been moved.

---

To move a value explicitly, call `std::move(x)` (`import std`). It takes `x` through a `@move` parameter, so `x` is moved-from afterwards, for every type, until it is assigned again. `std::copy(x)` returns a copy and leaves `x` untouched: it uses the type's `copy()` method if it declares one, otherwise its copy constructor, and is an error for a type with neither. A `const` binding cannot be passed to a `@move` parameter (SC301E), and a type that cannot be moved at all cannot be moved (SC051E):

```kairo
import std

var a = UniqueFile()
var b = std::move(a)   // a is moved-from
a = UniqueFile()       // a is usable again
```

## Summary

| Type category | Assignment | Source after | Function param        |
|---------------|------------|--------------|-----------------------|
| COPY          | Copy       | Live         | Copy (caller keeps)   |
| MOVE          | Move       | Invalidated  | Move (caller loses)   |
| NON_TRANSFER  | Error      | N/A          | Error                 |
| Struct        | memcpy     | Live         | memcpy (caller keeps) |

Escape and ownership violations resolve by *transforming the program* in debug (heap-lift, smart pointer promotion) and a *hard error with the fix* in release. They are never runtime checks that is reserved for access obligations like bounds. See [Tether The Residual Table](/docs/language/tether-proof-model/#the-residual-table).

```kairo
// COPY: both sides live after transfer
var a = Config()
var b = a              // copy
a.method()             // ok
b.method()             // ok

// MOVE: source invalidated after transfer
var x = UniqueFile()
var y = x              // move
// x.method()          // compile error
y.method()             // ok

// Pointer aliasing (single-threaded): allowed, Tether checks provenance
var val = 42
var *p = &val
var *q = &val
*p = 100
std::io::println(*q)       // 100

// Closure capture by value (default)
var m = UniqueFile()
var f = fn () { m.use() }
// m is moved into f

// Closure capture by pointer
var n = 0
var g = fn ()|*| { *n += 1 }
g()
// n is 1
```
## See also

- [Tether](/docs/language/tether/)
- [Ownership and Promotion](/docs/language/tether-promotion/)
- [Threading](/docs/language/tether-threading/)
- [Pointers](/docs/language/pointers/)
- [Class Lifecycle](/docs/language/classes-lifecycle/#lifecycle-categories)
- [Parameter Passing Modes](/docs/language/functions-parameter-modes/)
- [Closures](/docs/language/closures/)
- [Structures](/docs/language/structures/#copy-semantics)

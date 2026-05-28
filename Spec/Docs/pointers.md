# Pointers & Raw Pointers

Kairo has two pointer types: safe pointers (`*T`) with compiler-tracked lifetime and null checking, and
raw pointers (`unsafe *T`) with no tracking and no checks. Both are 8 bytes on 64-bit platforms and
hold a memory address.

---

## Safe Pointers (`*T`)

`*T` is the default pointer type. The compiler tracks its provenance via
[AMT](/docs/language/amt) and inserts null checks on dereference:

```kairo
var x = 42
var p: *i32 = &x     // p points to x
*p = 100              // dereference and assign null check inserted
std::println(*p)      // 100
```

### Non-Null Guarantee

`*T` cannot hold null. Attempting to assign `&null` to a `*T` is a compile error:

```kairo
var p: *i32 = &null   // compile error: *T is non-null

var x = 42
var p: *i32 = &x      // ok: p is guaranteed valid
*p = 100              // no null check needed
```

If you need a pointer that might be absent, use `*T?`:

```kairo
var p: *i32? = get_pointer()   // might be null

if p? {
    std::println(*p)   // safe: compiler has verified p is non-null
}
```

For raw nullable pointers with no compiler tracking, use `unsafe *T`:

```kairo
var raw: unsafe *i32 = &null   // ok: raw pointers can be null
if raw != &null {
    std::println(*raw)
}
```

### Member access

Use `->` to access members through a pointer:

```kairo
class Config {
    pub var port: i32
    fn Config(self, port: i32) { self.port = port }
}

var cfg = Config(8080)
var ptr: *Config = &cfg
ptr->port   // 8080
```

---

## Raw Pointers (`unsafe *T`)

`unsafe *T` is an untracked pointer with no null checks, no bounds checks, and no AMT provenance
tracking. It is equivalent to a raw C/C++ pointer:

```kairo
var x = 42
var p: unsafe *i32 = unsafe &x   // create raw pointer from safe binding
*p = 100                          // no null check
```

Dereferencing a null `unsafe *T` is undefined behavior. The compiler will not insert a check.

Raw pointers are required for [C/C++ interop](/docs/language/c-c++), custom allocators, hardware
register access, and any scenario where AMT tracking is not possible or not desired.

### Creating raw pointers

```kairo
// From a safe binding
var x = 42
var raw: unsafe *i32 = unsafe &x

// From heap allocation
var raw: unsafe *i32 = unsafe std::alloc<i32>(sizeof i32)

// From an integer address
var raw = 0x7FFE_0000_1000 as unsafe *i32

// Null
var raw: unsafe *i32 = &null
```

---

## `const` Pointers

The `const` binding rule applies to pointers left-to-right. `const` on the binding prevents
reassigning the pointer. `*const T` prevents modifying the pointed-to value:

```kairo
var ptr: *i32 = &x
// ptr is mutable, *ptr is mutable

const ptr: *i32 = &x
// ptr is const (cannot reassign), *ptr is mutable
*ptr = 10    // ok
ptr = &y     // compile error

var ptr: *const i32 = &x
// ptr is mutable (can reassign), *ptr is const
*ptr = 10    // compile error
ptr = &y     // ok

const ptr: *const i32 = &x
// both const
*ptr = 10    // compile error
ptr = &y     // compile error
```

See [Variables](/docs/language/variables#the-const-binding-rule) for the full `const` model.

---

## Pointer Arithmetic

### On safe pointers (`*T`)

Safe pointers support offset arithmetic with integers. The offset is in units of `sizeof T`:

```kairo
var arr: [i32; 4] = [10, 20, 30, 40]
var p: *i32 = &arr[0]

var second = *(p + 1)    // 20
var third = *(p + 2)     // 30
p = p - 1                // ok: reposition pointer
```

Pointer-to-pointer arithmetic (`p1 - p2`) is not permitted on safe pointers use `unsafe *T` for
that.

> [!CAUTION]
> Safe pointer arithmetic is bounds-checked by AMT only when provenance is trackable. If the pointer
> originates from a context where AMT cannot determine the allocation bounds, the arithmetic compiles
> but bounds safety is not guaranteed. Prefer array/vector indexing over pointer arithmetic when
> possible.

### On raw pointers (`unsafe *T`)

Raw pointers support all arithmetic operations with no checks:

```kairo
var p: unsafe *i32 = get_buffer()
var q: unsafe *i32 = p + 10      // offset by 10 i32s (40 bytes)

var distance = q - p              // 10 (pointer difference in units of sizeof i32)
```

Out-of-bounds access through raw pointer arithmetic is undefined behavior.

---

## Array-Style Indexing

Pointers support bracket indexing, which desugars to offset + dereference:

```kairo
var p: *i32 = &arr[0]
p[0]    // same as *(p + 0)
p[2]    // same as *(p + 2)
```

Bounds checking follows the same rules as pointer arithmetic AMT checks when provenance is
trackable, no checks on `unsafe *T`.

---

## Void Pointers

`*void` and `unsafe *void` are opaque pointers that hold an address without type information.
They cannot be dereferenced cast to a typed pointer first:

```kairo
var handle: unsafe *void = get_opaque_handle()

// *handle             // compile error: cannot dereference void pointer
var typed = handle as unsafe *i32
var value = *typed     // ok: typed pointer
```

Void pointers are used for type-erased APIs, opaque handles, and C interop where the concrete type
is not known at the Kairo call site.

---

## Double Pointers

Pointers to pointers are legal and follow the same rules recursively:

```kairo
var x = 42
var p: *i32 = &x
var pp: **i32 = &p

**pp = 100   // x is now 100
```

`const` applies at each level independently:

```kairo
const pp: *const *i32 = &p
// pp cannot be reassigned
// *pp (the inner pointer) cannot be reassigned
// **pp (the i32) can be modified
```

---

## Smart Pointer Promotion

[AMT](/docs/language/amt) analyzes pointer usage and automatically promotes safe pointers to smart
pointers when needed. The smart pointer types are compiler intrinsics exposed through the standard
library:

| Type | Description |
|---|---|
| `std::Unique<*T>` | Single-owner, exclusive access, freed on drop |
| `std::Shared<*T>` | Reference-counted, multiple owners, freed when count reaches zero |
| `std::Weak<*T>` | Non-owning reference to a `Shared` allocation, does not prevent deallocation |

AMT decides which smart pointer type to use based on how the pointer is used across the program. The
programmer does not need to annotate or choose AMT handles it automatically:

```kairo
fn make_config() -> *Config {
    var cfg = std::create<Config>(8080)
    return cfg   // AMT determines ownership: likely Unique or Shared
}
```

If AMT cannot determine a safe promotion path (e.g., the pointer escapes in a way that prevents
tracking), it emits a compile error rather than allowing unsafe behavior.

Smart pointer types can be used explicitly to override AMT's decision or to validate compiler
behavior:

```kairo
var ptr: std::Unique<*Config> = std::create<Config>(8080)
var shared: std::Shared<*Config> = std::create<Config>(8080)
```

See [AMT](/docs/language/amt) for the full lifetime and promotion model, and
[Ownership](/docs/language/ownership) for borrowing semantics.

---

## Heap Allocation

Stack allocation is the default. Heap allocation uses `std::create<T>()`:

```kairo
var stack_val = Config(8080)                    // stack-allocated
var heap_ptr = std::create<Config>(8080)        // heap-allocated, AMT chooses pointer type
```

For raw heap allocation without AMT tracking:

```kairo
var raw = unsafe std::alloc<i32>(sizeof i32 * 10)   // raw allocation, 10 i32s
// must be manually freed
unsafe std::free(raw)
```

See [AMT](/docs/language/amt) for how allocation interacts with lifetime tracking.

---

## Pointer Comparison

| Operator | Behavior |
|---|---|
| `==` | Compares addresses do both pointers point to the same location? |
| `!=` | Negation of `==` |
| `===` | Deep equality dereferences both pointers and compares the values |

```kairo
var a = 42
var b = 42
var p = &a
var q = &b

p == q    // false: different addresses
p === q   // true: both point to 42

var r = &a
p == r    // true: same address
```

`===` performs a null check before dereferencing. If either pointer is null, `===` returns `false`
(two null pointers are not deeply equal there is no value to compare).

See [Operators](/docs/language/operators#comparison) for the full comparison model.

---

## Function Pointers

Function pointers (`fn(T) -> R`) are a separate type from `*T`. They are opaque values that cannot
be cast to data pointers or vice versa:

```kairo
fn add(a: i32, b: i32) -> i32 = a + b
var f: fn(i32, i32) -> i32 = add

// var p = f as unsafe *void   // compile error: function pointers are not data pointers
```

See [Functions](/docs/language/functions#function-pointers) for function pointer syntax and
[Closures](/docs/language/closures) for closures as function pointers.

---

## Pointers and Nullable Types

`*T` is non-null by construction. To represent a pointer that might not exist, use `*T?` which
wraps the pointer in the standard `Nullable<T>` system:

| | `*T` | `*T?` | `unsafe *T` |
|---|---|---|---|
| Can be null | No | Yes | Yes |
| Null check mechanism | N/A | `?.`, `??`, `unwrap!()`, `val?` | `ptr != &null` (manual) |
| Dereference null | Cannot happen | Compile error (must check first) | Undefined behavior |
| AMT tracked | Yes | Yes | No |

`*T?` supports the same null-handling operators as any other nullable type. `unsafe *T` uses
manual null comparison, it does not participate in the `Nullable<T>` system.

```kairo
var p: *i32 = &x            // always valid, no null check needed
var q: *i32? = find_ptr()   // might be null must check before use
var r: unsafe *i32 = &null  // raw pointer, nullable, no tracking

if q? {
    std::println(*q)         // compiler knows q is non-null here
}

var val = q ?? &fallback     // use fallback pointer if q is null
var forced = unwrap!(q)      // panics if null
```

See [Variables](/docs/language/variables#nullable-types) for the full nullable type system.

---

## Summary

```kairo
// Safe pointer
var x = 42
var p: *i32 = &x
*p = 100

// Raw pointer
var raw: unsafe *i32 = unsafe &x

// Null
var null_ptr: *i32 = &null
if null_ptr != &null {
    std::println(*null_ptr)
}

// Const pointer
var ptr: *const i32 = &x    // mutable pointer to const value
const ptr: *i32 = &x        // const pointer to mutable value

// Pointer arithmetic
var arr: [i32; 4] = [10, 20, 30, 40]
var p: *i32 = &arr[0]
*(p + 2)   // 30

// Heap allocation
var heap = std::create<Config>(8080)

// Smart pointer (explicit)
var unique: std::Unique<*Config> = std::create<Config>(8080)

// Void pointer
var opaque: unsafe *void = get_handle()
var typed = opaque as unsafe *i32

// Double pointer
var pp: **i32 = &p
**pp = 999

// Comparison
p == q     // address comparison
p === q    // deep value comparison
```

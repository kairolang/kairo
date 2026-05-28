# Unsafe

The `unsafe` keyword appears in three distinct contexts in Kairo, each serving a different purpose:

| Context | Meaning |
|---|---|
| `unsafe { ... }` | Block that suspends AMT tracking |
| `unsafe *T` | Raw pointer type with no compiler tracking |
| `fn foo() unsafe -> T` | Separate function overload namespace |

These are independent mechanisms that share a keyword. An `unsafe` block does not make all pointers
raw, and a raw pointer does not require an `unsafe` block to use.

---

## Unsafe Blocks

An `unsafe { ... }` block suspends [AMT](/docs/language/amt) for all operations within its scope.
Inside an unsafe block:

- AMT does not track pointer lifetimes or provenance
- AMT does not insert automatic destructors or smart pointer promotions
- `forget!()` is available to permanently drop pointers from AMT tracking
- `unsafe &x` can create raw pointers from safe bindings

```kairo
var x = std::create<i32>(42)   // AMT-tracked safe pointer

unsafe {
    forget!(x)                  // drop x from AMT tracking
    c_function(x as unsafe *i32)  // pass to C++ which will free it
}

// x is no longer tracked AMT will not auto-free it
```

### When unsafe blocks are required

An `unsafe` block is required when calling a C/C++ function that takes or returns raw pointers:

```kairo
ffi "c++" import "native.hh";

fn main() {
    var data = std::create<i32>(100)

    unsafe {
        forget!(data)
        native_take_ownership(data as unsafe *i32)
    }
}
```

### When unsafe blocks are NOT required

Calling C/C++ functions that use safe parameter types does not require an `unsafe` block:

| C++ parameter type | Requires `unsafe` block |
|---|---|
| Value types (`int`, `float`, structs by value) | No |
| References (`T&`, `const T&`) | No |
| Move references (`T&&`) | No |
| `std::unique_ptr<T>` | No |
| `std::shared_ptr<T>` | No |
| `std::weak_ptr<T>` | No |
| Raw pointers (`T*`, `void*`) | Yes |

The FFI layer reads C++ declaration signatures and maps C++ smart pointers to Kairo's
AMT-tracked equivalents automatically. `std::unique_ptr<T>` maps to `std::Unique<*T>`,
`std::shared_ptr<T>` maps to `std::Shared<*T>`, `std::weak_ptr<T>` maps to `std::Weak<*T>`.
A mismatch between AMT's promotion and the C++ function's expected smart pointer type is a
compile error.

See [C/C++ Interop](/docs/language/c-c++) for the full FFI model.

---

## `forget!()`

`forget!()` is a compiler intrinsic that permanently removes a pointer from AMT tracking. It is
only valid inside an `unsafe` block:

```kairo
var ptr = std::create<Config>(8080)

unsafe {
    forget!(ptr)   // AMT stops tracking ptr
    // ptr is now the caller's responsibility
}

// AMT will not auto-free ptr if nothing else frees it, this is a memory leak
```

The primary use case is transferring ownership to C++ code that will manage the pointer's lifetime:

```kairo
ffi "c++" import "engine.hh";

fn init_engine() {
    var cfg = std::create<EngineConfig>(defaults())

    unsafe {
        forget!(cfg)
        engine_init(cfg as unsafe *EngineConfig)
        // C++ engine now owns the allocation and will free it on shutdown
    }
}
```

> [!CAUTION]
> `forget!()` does not free memory it tells AMT to stop tracking the pointer. If the pointer is
> not freed by other means (C++ code, manual `std::free()`, etc.), the memory leaks. Use `forget!()`
> only when transferring ownership across the FFI boundary.

---

## Raw Pointers (`unsafe *T`)

`unsafe *T` declares a pointer with no AMT tracking, no null checks, and no bounds checks. It is
the Kairo equivalent of a raw C/C++ pointer:

```kairo
var raw: unsafe *i32 = unsafe &some_value
*raw = 42   // no null check UB if null
```

Raw pointers do not require an `unsafe` block to dereference or use. The `unsafe` is part of the
type itself by declaring the pointer as `unsafe *T`, the programmer has already opted out of
safety for that pointer.

```kairo
var buf: unsafe *u8 = unsafe std::alloc<u8>(1024)
buf[0] = 0xFF      // no bounds check
buf[100] = 0x00    // no bounds check UB if out of allocation
unsafe std::free(buf)
```

See [Pointers](/docs/language/pointers) for the full pointer model.

---

## Unsafe Function Overloads

The `unsafe` modifier on a function creates a separate overload in its own namespace. The caller
explicitly selects the unsafe variant with the `unsafe` keyword:

```kairo
fn sort(data: [i32]) -> [i32] {
    // safe: bounds-checked, stable sort
    return stable_sort(data)
}

fn sort(data: [i32]) unsafe -> [i32] {
    // unsafe: unstable sort, may reorder equal elements
    return quick_sort(data)
}

var a = sort(my_data)           // calls the safe version
var b = unsafe sort(my_data)    // calls the unsafe version
```

### What `unsafe` means on a function

`unsafe` on a function does **not** mean "unsafe memory." AMT still guarantees memory safety in
both safe and unsafe overloads. The `unsafe` qualifier signals that the function may not uphold
semantic invariants that the safe version does stability, ordering, precision, idempotency,
or any other contract beyond memory safety.

The caller writing `unsafe sort(...)` is explicitly acknowledging: "I know this version has weaker
guarantees and I accept the trade-off."

### Overload resolution

Safe and unsafe overloads live in separate namespaces. They can have identical parameter types
because the dispatch is determined by the presence or absence of the `unsafe` keyword at the
call site:

```kairo
fn process(x: i32) -> i32 { ... }        // safe
fn process(x: i32) unsafe -> i32 { ... }  // unsafe different namespace

process(42)          // calls safe version
unsafe process(42)   // calls unsafe version
```

### Modifier restrictions

`unsafe` cannot be combined with other function modifiers:

| Combination | Valid |
|---|---|
| `unsafe` + `const` | Yes |
| `unsafe` + `eval` | No |
| `unsafe` + `async` | Yes |
| `unsafe` + `panic` | Yes |
| `unsafe` + `inline` | Yes |
| `unsafe` + `volatile` | Yes |

`unsafe` stands alone as an overload qualifier. See
[Functions](/docs/language/functions#modifier-compatibility) for the full modifier compatibility
table.

---

## The Safety Boundary

Kairo's safety model has a clear boundary:

**Inside normal code:** AMT tracks all pointer lifetimes, inserts null checks on safe pointer
dereference, auto-promotes to smart pointers, and emits compile errors when safety cannot be
guaranteed. Memory safety is the compiler's responsibility.

**Inside `unsafe { }` blocks:** AMT is suspended. The programmer is responsible for pointer
lifetimes, null safety, and deallocation. The compiler trusts the programmer.

**With `unsafe *T` pointers:** No tracking regardless of whether the code is inside an `unsafe`
block. The pointer is permanently untracked by its type.

**With `unsafe` function overloads:** Memory safety is still guaranteed by AMT. Only semantic
invariants beyond memory safety are relaxed.

```
                    Memory safe?    AMT tracked?    Who manages lifetime?
Normal code         Yes             Yes             Compiler (AMT)
unsafe { }          Programmer      No              Programmer
unsafe *T           Programmer      No              Programmer
fn foo() unsafe     Yes             Yes             Compiler (AMT)
```

---

## Common Patterns

### FFI ownership transfer

```kairo
ffi "c++" import "lib.hh";

fn send_to_native(data: Config) {
    var ptr = std::create<Config>(data)

    unsafe {
        forget!(ptr)
        native_take_ownership(ptr as unsafe *i32)
    }
}
```

### Custom allocator

```kairo
fn allocate_aligned(size: usize, align: usize) -> unsafe *void {
    var raw: unsafe *void = unsafe std::aligned_alloc(align, size)
    return raw
}
```

### Interfacing with hardware registers

```kairo
fn write_register(addr: usize, value: u32) {
    var reg = addr as unsafe *u32
    *reg = value
}
```

### Unsafe overload for performance

```kairo
fn bounds_check(arr: [i32], index: i32) -> i32 {
    assert index >= 0 && index < arr.len(), "out of bounds"
    return arr[index]
}

fn bounds_check(arr: [i32], index: i32) unsafe -> i32 {
    // caller guarantees index is valid skip the check
    return arr[index]
}
```

---

## Summary

```kairo
// Unsafe block suspends AMT
var ptr = std::create<i32>(42)
unsafe {
    forget!(ptr)
    c_function(ptr as unsafe *i32)
}

// Raw pointer no tracking by type
var raw: unsafe *i32 = unsafe &some_value
*raw = 100   // no null check

// Unsafe overload separate dispatch namespace
fn compute(x: f64) -> f64 { /* precise */ }
fn compute(x: f64) unsafe -> f64 { /* fast approximation */ }

var precise = compute(3.14)
var fast = unsafe compute(3.14)

// forget!() drop pointer from AMT
var data = std::create<Buffer>(1024)
unsafe {
    forget!(data)
    // data is no longer tracked manual management required
}
```
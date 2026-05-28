# Primitives

Kairo's primitive types are built into the language and available without imports. They map directly to
hardware-supported representations where possible, falling back to software emulation for extended-width types.

---

## Integers

All integer types have a fixed, guaranteed size. The default integer type is `i32` if a literal doesn't fit
in `i32`, the compiler promotes it to the smallest signed type that can hold the value, up to `i512`.

| Type | Size | Description | C++ Equivalent |
|---|---|---|---|
| `u8` | 1 byte | Unsigned 8-bit integer | `uint8_t` |
| `u16` | 2 bytes | Unsigned 16-bit integer | `uint16_t` |
| `u32` | 4 bytes | Unsigned 32-bit integer | `uint32_t` |
| `u64` | 8 bytes | Unsigned 64-bit integer | `uint64_t` |
| `u128` | 16 bytes | [Unsigned 128-bit integer]((#extended-width-integers-u128u512-i128i512)) | `__uint128_t` |
| `u256` | 32 bytes | [Unsigned 256-bit integer]((#extended-width-integers-u128u512-i128i512)) |   |
| `u512` | 64 bytes | [Unsigned 512-bit integer]((#extended-width-integers-u128u512-i128i512)) |   |
| `i8` | 1 byte | Signed 8-bit integer | `int8_t` |
| `i16` | 2 bytes | Signed 16-bit integer | `int16_t` |
| `i32` | 4 bytes | Signed 32-bit integer | `int32_t` |
| `i64` | 8 bytes | Signed 64-bit integer | `int64_t` |
| `i128` | 16 bytes | [Signed 128-bit integer](#extended-width-integers-u128u512-i128i512) | `__int128_t` |
| `i256` | 32 bytes | [Signed 256-bit integer](#extended-width-integers-u128u512-i128i512) |   |
| `i512` | 64 bytes | [Signed 512-bit integer](#extended-width-integers-u128u512-i128i512) |   |
| `usize` | Platform-dependent | Unsigned, pointer-width integer | `size_t` |
| `isize` | Platform-dependent | Signed, pointer-width integer | `ptrdiff_t` |

Integer literals default to signed. Use a type suffix to specify:

```kairo
var a = 42          // i32 (default)
var b = 42u8        // u8
var c = 42i64       // i64
var d = 1_000_000   // i32 underscores are ignored, use freely as separators
var e = 0xFF        // i32 hexadecimal
var f = 0b1010_0011 // i32 binary
var g = 0o77        // i32 octal
```

### Overflow behavior

Unsigned integer overflow wraps around (modular arithmetic). Signed integer overflow behavior depends on the
build mode:

- **Debug:** crashes with a diagnostic.
- **Release:** wraps around silently.

This matches Rust's overflow model and catches bugs during development without paying for checks in production.

### Extended-width integers (u128–u512, i128–i512)

If the target hardware supports wide registers (e.g., AVX-512), these types map directly to hardware. Otherwise,
the compiler stores them as structs of smaller integers and emits SIMD-accelerated arithmetic when available,
falling back to scalar multi-word operations.

Extended-width integers are always stack-allocated they are value types, not heap-allocated objects.

---

## Floating-Point

All floating-point types follow the IEEE 754 standard. The default float type is `f64` if a literal doesn't
fit in `f64`, the compiler promotes to the smallest float type that can hold the value, up to `f512`.

| Type | Size | Precision | C++ Equivalent |
|---|---|---|---|
| `f16` | 2 bytes | Half (IEEE 754-2008) | `_Float16` |
| `f32` | 4 bytes | Single | `float` |
| `f64` | 8 bytes | Double | `double` |
| `f128` | 16 bytes | Quadruple | `__float128` |
| `f256` | 32 bytes | Extended (software) |   |
| `f512` | 64 bytes | Extended (software) |   |

```kairo
var x = 3.14        // f64 (default)
var y = 3.14f32     // f32
var z = 1.0e-10     // f64 scientific notation
```

Overflow produces `inf`, underflow produces `0.0`. Operations that produce `NaN` (e.g., `0.0 / 0.0`,
`sqrt(-1.0)`) propagate `NaN` per IEEE 754 no crash, no trap. Check for `NaN` explicitly with
`std::is_nan()` when needed.

> [!NOTE]
> `f256` and `f512` are not natively supported on any current hardware and are implemented entirely in software,
> using SIMD instructions when available. Like extended-width integers, they are stack-allocated value types.
> Expect significantly lower performance compared to hardware-backed float types.

---

## Implicit Conversions

Integer and float types can be **implicitly widened** `i32` to `i64`, `f32` to `f64` but narrowing
conversions require an explicit cast. See [Casting](/docs/language/casting) for details.

```kairo
var a: i32 = 42
var b: i64 = a      // ok: implicit widening

var c: i64 = 1000
var d: i8 = c        // compile error: narrowing requires explicit cast
var e: i8 = c as i8  // ok: explicit, may truncate
```

---

## Bool

| Type | Size | C++ Equivalent |
|---|---|---|
| `bool` | 1 byte | `bool` |

```kairo
var flag = true
var other = false
```

`bool` is 1 byte in memory (not 1 bit) for addressability. Only `true` and `false` are valid values no
implicit conversion from integers.

---

## Char

| Type | Size | Description | C++ Equivalent |
|---|---|---|---|
| `char` | 4 bytes | Unicode scalar value (U+0000–U+10FFFF) | `char32_t` |

A `char` holds a single decoded Unicode codepoint. It is always 4 bytes regardless of which codepoint it
represents.

```kairo
var letter = 'A'
var emoji = '😶‍🌫'
var cjk = '漢'
```

> [!NOTE]
> `char` is the *decoded* representation of a single codepoint. Strings store text as UTF-8 bytes internally,
> not as arrays of `char`. See [Strings](#strings) below.

---

## Byte

| Type | Size | C++ Equivalent |
|---|---|---|
| `byte` | 1 byte | `std::byte` |

`byte` is semantically identical to `u8` in size and representation but restricted to bitwise operations and
comparisons no arithmetic. It represents raw data where the value is not meant to be interpreted as a number.

```kairo
var b: byte = 0xFF
var mask: byte = 0x0F
var result = b & mask   // ok: bitwise AND
// var bad = b + mask   // compile error: arithmetic not allowed on byte
```

---

## Strings

| Type | Size | Encoding | C++ Equivalent |
|---|---|---|---|
| `string` | 32 bytes | UTF-8 | `std::string` |

Strings are UTF-8 encoded byte sequences. The `string` type uses small string optimization (SSO) strings up
to 23 bytes are stored inline without a heap allocation. Longer strings are heap-allocated.

```kairo
var greeting = "Hello, Kairo! 📣"   // 18 UTF-8 bytes fits in SSO
var name = "Dhruvan"                 // 7 bytes SSO
```

Because UTF-8 is a variable-width encoding, indexing by codepoint (`s[i]`) is O(1) amortized (since it looks up the nearest codepoint boundary and decodes from there), while indexing by byte (`s.bytes[i]`) is O(1) always, but returns raw bytes, not characters.

```kairo
var s = "Hello 📣"
s.bytes[0]    // byte: 0x48 ('H') O(1)
s[6]          // char: '📣' codepoint indexing, O(1) **amortized**

for ch in s {
    // ch is char decoded codepoint, yielded sequentially
}
```

> [!IMPORTANT]
> The stdlib API for strings is still being finalized. Detailed documentation for string methods will be added
> in a future update.

---

## Void

| Type | Size | C++ Equivalent |
|---|---|---|
| `void` | 0 bytes | `void` |

`void` indicates the absence of a value. It can be used as a function return type and as the target of an
`unsafe` pointer (`unsafe *void`), but it cannot be used as a type parameter or variable type.

```kairo
fn log(msg: string) -> void {
    // ...
}

var opaque: unsafe *void = get_handle()  // raw, untyped pointer
```

---

## Pointers

| Type | Size | Description |
|---|---|---|
| `*T` | 8 bytes | Safe pointer non-null, compiler-tracked |
| `unsafe *T` | 8 bytes | Raw pointer nullable, no safety checks |

`*T` is a thin pointer (8 bytes). It is non-null by construction and supports pointer arithmetic when the compiler can track its provenance via [AMT](/docs/language/amt). See [Pointers](/docs/language/pointers) for full details.

`unsafe *T` is a raw C-style pointer with no compiler tracking. It can be null, and dereferencing a null

`unsafe *T` is undefined behavior. Use `unsafe *T` for [C/C++ interop](/docs/language/c-c++), custom allocators, and other low-level scenarios. See [Pointers](/docs/language/pointers) and [Unsafe](/docs/language/unsafe) for full details.

```kairo
var x = 42
var p: *i32 = &x          // safe pointer to x
var q: unsafe *i32 = unsafe &x  // raw pointer, no tracking
```

---

## Collections

Collections are built-in generic types with literal syntax. All are heap-allocated except fixed-size arrays.

### Vectors `[T]`

A growable, owning, contiguous array. Layout: `ptr + len + cap` (24 bytes).

```kairo
var nums: [i32] = [1, 2, 3]
nums.push(4)
nums[0]    // 1 bounds-checked
```

When borrowed as `const [T]`, a vector acts as a non-owning view with `cap` set to zero no growth permitted,
no deallocation on drop. See [Ownership](/docs/language/ownership) for borrowing semantics.

### Arrays `[T; N]`

A fixed-size array allocated inline (stack or struct). `N` must be a compile-time constant.

```kairo
var rgb: [u8; 3] = [255, 128, 0]
// rgb.push(42)  // compile error: fixed size
```

### Maps `{K: V}`

A hash map from keys of type `K` to values of type `V`.

```kairo
var ages: {string: i32} = {"Alice": 30, "Bob": 25}
ages["Charlie"] = 35
```

### Sets `{T}`

A hash set of unique elements.

```kairo
var primes: {i32} = {2, 3, 5, 7, 11}
```

### Tuples `(T1, T2, ...)`

A fixed-size, heterogeneous, ordered group of values. Stored contiguously with padding for alignment.

```kairo
var point: (f64, f64) = (1.0, 2.0)
var record: (i32, string, bool) = (42, "Answer", true)
```

### Function Pointers `fn (T1, T2, ...) -> R`

A pointer to a function with the given signature. Platform-dependent size.

```kairo
fn add(a: i32, b: i32) -> i32 { return a + b }
var operator: fn (i32, i32) -> i32 = add
op(3, 4)  // 7
```

> [!IMPORTANT]
> The stdlib API for vectors, maps, and sets is still being finalized. Detailed method documentation will be
> added in a future update.

---

## Platform-Dependent Sizes

`usize` and `isize` match the target platform's pointer width:

| Platform | `usize` / `isize` |
|---|---|
| 64-bit | 8 bytes |
| 32-bit | 4 bytes |
| 16-bit | 2 bytes |

---

## Summary

```kairo
// Integers
var a = 42              // i32
var b = 42u8            // u8
var c = 0xFF            // i32 (hex)
var d = 0b1010          // i32 (binary)
var e = 1_000_000       // i32 (underscores as separators)

// Floats
var f = 3.14            // f64
var g = 3.14f32         // f32

// Bool, char, string
var h = true            // bool
var i = '📣'            // char (4 bytes, Unicode scalar)
var j = "Hello, Kairo!" // string (UTF-8, SSO up to 23 bytes)

// Byte
var k: byte = 0xFF      // raw byte, no arithmetic

// Pointers
var x = 42
var p = &x              // *i32
var q: unsafe *i32 = unsafe &x

// Collections
var nums: [i32] = [1, 2, 3]                           // vector
var rgb: [u8; 3] = [255, 128, 0]                      // array
var ages: {string: i32} = {"Alice": 30, "Bob": 25}    // map
var primes: {i32} = {2, 3, 5, 7}                      // set
var point: (f64, f64) = (1.0, 2.0)                    // tuple

// Function pointer
fn add(a: i32, b: i32) -> i32 { return a + b }
var operator: fn (i32, i32) -> i32 = add
```

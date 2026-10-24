# Primitives

Kairo's primitive types are built into the language and available without imports. They map directly to hardware-supported representations where possible, falling back to software emulation for extended-width types.

---

## Integers

All integer types have a fixed, guaranteed size. An integer literal takes the type expected by its context (annotation, parameter, return position, the other operand) and must fit it. With no expected type the default is `i32`; only if the value does not fit `i32` does the compiler fall back to the smallest signed type that can hold it, up to `i512`. See [Literal inference](#5-literal-inference-a-separate-mechanism).

| Type | Size | Description | C++ Equivalent |
|---|---|---|---|
| `u8` | 1 byte | Unsigned 8-bit integer | `uint8_t` |
| `u16` | 2 bytes | Unsigned 16-bit integer | `uint16_t` |
| `u32` | 4 bytes | Unsigned 32-bit integer | `uint32_t` |
| `u64` | 8 bytes | Unsigned 64-bit integer | `uint64_t` |
| `u128` | 16 bytes | [Unsigned 128-bit integer](#extended-width-integers-u128-u512-i128-i512) | `__uint128_t` |
| `u256` | 32 bytes | [Unsigned 256-bit integer](#extended-width-integers-u128-u512-i128-i512) |   |
| `u512` | 64 bytes | [Unsigned 512-bit integer](#extended-width-integers-u128-u512-i128-i512) |   |
| `i8` | 1 byte | Signed 8-bit integer | `int8_t` |
| `i16` | 2 bytes | Signed 16-bit integer | `int16_t` |
| `i32` | 4 bytes | Signed 32-bit integer | `int32_t` |
| `i64` | 8 bytes | Signed 64-bit integer | `int64_t` |
| `i128` | 16 bytes | [Signed 128-bit integer](#extended-width-integers-u128-u512-i128-i512) | `__int128_t` |
| `i256` | 32 bytes | [Signed 256-bit integer](#extended-width-integers-u128-u512-i128-i512) |   |
| `i512` | 64 bytes | [Signed 512-bit integer](#extended-width-integers-u128-u512-i128-i512) |   |
| `usize` | Platform-dependent | Unsigned, pointer-width integer | `size_t` |
| `isize` | Platform-dependent | Signed, pointer-width integer | `ptrdiff_t` |

`i64` and `u64` are spelled as the target's `int64_t` / `uint64_t`, not hard-coded: `long` on 64-bit Linux and FreeBSD; `long long` on Windows, on every 32-bit target, and on Darwin (a 64-bit platform that still spells `int64_t` as `long long`). This keeps C++ name mangling and header signatures matching on every target.

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

Unsigned integer overflow wraps around (modular arithmetic). Signed integer overflow behavior depends on the build mode:

- **Debug:** crashes with a diagnostic.
- **Release:** wraps around silently.

This matches Rust's overflow model and catches bugs during development without paying for checks in production.

### Extended-width integers (u128-u512, i128-i512)

If the target hardware supports wide registers (e.g., AVX-512), these types map directly to hardware. Otherwise, the compiler stores them as structs of smaller integers and emits SIMD-accelerated arithmetic when available, falling back to scalar multi-word operations.

Extended-width integers are always stack-allocated they are value types, not heap-allocated objects.

---

## Floating-Point

All floating-point types except `f80` follow the IEEE 754 standard. A float literal takes the type expected by its context and must fit it. With no expected type the default is `f64`; only if the value does not fit `f64` does the compiler fall back to the smallest float type that can hold it, up to `f512`.

| Type | Size | Precision | C++ Equivalent |
|---|---|---|---|
| `f16` | 2 bytes | Half (IEEE 754-2008) | `_Float16` |
| `f32` | 4 bytes | Single | `float` |
| `f64` | 8 bytes | Double | `double` |
| `f80` | 16 bytes (12 on i386); 10 hold the value | x87 extended; only on some targets, see below | `long double` |
| `f128` | 16 bytes | Quadruple | `__float128` |
| `f256` | 32 bytes | Extended (software) |   |
| `f512` | 64 bytes | Extended (software) |   |

```kairo
var x = 3.14        // f64 (default)
var y = 3.14f32     // f32
var z = 1.0e-10     // f64 scientific notation
```

Overflow produces `inf`, underflow produces `0.0`. Operations that produce `NaN` (e.g., `0.0 / 0.0`, `sqrt(-1.0)`) propagate `NaN` per IEEE 754 no crash, no trap. Check for `NaN` explicitly with `std::is_nan()` when needed.

> [!NOTE]
> `f256` and `f512` are not natively supported on any current hardware and are implemented entirely in software, using SIMD instructions when available. Like extended-width integers, they are stack-allocated value types. Expect significantly lower performance compared to hardware-backed float types.

### `f80` follows the target's `long double`

`f80` is the x87 80-bit extended format, and it is C's `long double`. It exists only where the target ABI's `long double` is x87 extended precision. That is a property of the ABI, not the CPU:

| Target | `long double` | `f80` |
|---|---|---|
| x86_64 Linux, BSD, macOS | x87 extended | available |
| i386 Linux | x87 extended | available |
| x86_64 Windows (MSVC) | binary64, despite the x87 hardware | not available |
| x86_64 Android | binary128 | not available |
| AArch64 and RISC-V Linux | binary128 | not available |
| Apple ARM, Windows on ARM | binary64 | not available |

Anywhere else, writing `f80` is an error ([P003E](/docs/language/diagnostics/#p003e-a-primitive-type-is-not-available-on-the-target)). The error names the target and what its `long double` is, and suggests `f64` where `long double` is binary64 and `f128` where it is binary128. Kairo never silently substitutes another float type for `f80`.

```kairo
// building for x86_64-unknown-linux-gnu
var x: f80 = 1.0    // ok

// building for aarch64-unknown-linux-gnu
var y: f80 = 1.0    // error P003E: long double is binary128 here; use f128
```

---

## Implicit Conversions

Integer and float types can be **implicitly widened** `i32` to `i64`, `f32` to `f64` but narrowing conversions require an explicit cast. See [Casting](/docs/language/casting/) for details.

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

`bool` is 1 byte in memory (not 1 bit) for addressability. Only `true` and `false` are valid values no implicit conversion from integers.

---

## Char

| Type | Size | Description | C++ Equivalent |
|---|---|---|---|
| `char` | 4 bytes | Unicode scalar value (U+0000-U+10FFFF) | `char32_t` |

A `char` holds a single decoded Unicode codepoint. It is always 4 bytes regardless of which codepoint it represents.

```kairo
var letter = 'A'
var emoji = '😶‍🌫'
var cjk = '漢'
```

> [!NOTE]
> `char` is the *decoded* representation of a single codepoint. Strings store text as UTF-8 bytes internally, not as arrays of `char`. See [Strings](#strings) below.

---

## Byte

| Type | Size | C++ Equivalent |
|---|---|---|
| `byte` | 1 byte | `std::byte` |

`byte` is semantically identical to `u8` in size and representation but restricted to bitwise operations and comparisons no arithmetic. It represents raw data where the value is not meant to be interpreted as a number.

```kairo
var b: byte = 0xFF
var mask: byte = 0x0F
var result = b & mask   // ok: bitwise AND
// var bad = b + mask   // compile error: arithmetic not allowed on byte
```

---

## Strings

| Type | Size | Encoding |
|---|---|---|
| `string` | 4 words (32 bytes on 64-bit) | UTF-8 |

A `string` is a UTF-8 byte sequence. Its fields are public:

```kairo
struct string {
    var data:   *const u8   // the bytes
    var len:    usize       // length in bytes
    var cp_len: usize       // number of codepoints the bytes encode
    var cap:    usize       // heap capacity in bytes; 0 for a borrowed string
}
```

`len` counts bytes, not characters; `cp_len` counts codepoints, and `len == cp_len` means the string is ASCII. A string literal is a borrowed view of static storage: it allocates nothing, and its `cap` is `0`. An owned string has `cap` bytes of heap memory behind `data`. Both kinds keep a NUL byte after the last byte, so `data` can be [passed to C as a C string](/docs/language/c-cpp-calling/#strings-and-const-char).

```kairo
var greeting = "Hello, Kairo! 📣"   // len 18, cp_len 15, no allocation
var name     = "Name"               // len 4, cp_len 4
```

Because UTF-8 is a variable-width encoding, indexing by codepoint (`s[i]`) complexity depends on how the string was constructed. For string literals, the compiler pre-populates a breadcrumb cache at codegen time mapping codepoint positions to byte offsets, making indexing O(1) with zero runtime cost. For strings constructed at runtime from a raw pointer, no cache is available and indexing is O(n). Indexing by byte (`s.bytes[i]`) is always O(1) but returns raw `u8` bytes, not characters.

```kairo
var s = "Hello 📣"
s.bytes[0]    // byte: 0x48 ('H') O(1)
s[6]          // char: '📣' codepoint indexing, O(1) for literals (compiler cache), O(n) for runtime-constructed strings

for ch in s {
    // ch is char decoded codepoint, yielded sequentially
}
```

> [!IMPORTANT]
> The stdlib API for strings is still being finalized. Detailed documentation for string methods will be added in a future update.

---

## Void

| Type | Size | C++ Equivalent |
|---|---|---|
| `void` | 0 bytes | `void` |

`void` indicates the absence of a value. It can be used as a normal type and as the target of an `unsafe` pointer (`unsafe *void`), using `void` as a normal type denotes a unit type.

```kairo
fn log(msg: string) -> void {
    // ...
}

var opaque: unsafe *void = get_handle()  // raw, untyped pointer
var void_t: MyObj<void> = MyObj<void>()  // void is valid here
```

---

## Pointers

| Type | Size | Description |
|---|---|---|
| `*T` | 8 bytes | Safe pointer non-null, compiler-tracked |
| `unsafe *T` | 8 bytes | Raw pointer nullable, no safety checks |

`*T` is a thin pointer (8 bytes). It is non-null by construction and supports pointer arithmetic when the compiler can track its provenance via [Tether](/docs/language/tether/). See [Pointers](/docs/language/pointers/) for full details.

`unsafe *T` is a raw C-style pointer with no compiler tracking. It can be null, and dereferencing a null

`unsafe *T` is undefined behavior. Use `unsafe *T` for [C/C++ interop](/docs/language/c-cpp/), custom allocators, and other low-level scenarios. See [Pointers](/docs/language/pointers/) and [Unsafe](/docs/language/unsafe/) for full details.

```kairo
var x = 42
var p: *i32 = &x                // safe pointer to x
var q: unsafe *i32 = unsafe &x  // raw pointer, no tracking
```

---

Arrays, slices, vectors, list literals, maps, sets, tuples and function pointers are covered in [Collections](/docs/language/collections/).

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
var j = "Hello, Kairo!" // string (UTF-8)

// Byte
var k: byte = 0xFF      // raw byte, no arithmetic

// Pointers
var x = 42
var p = &x              // *i32
var q: unsafe *i32 = unsafe &x

// Collections
var nums: [i32] = [1, 2, 3]                           // vector
var view: [i32;] = [1, 2, 3]                          // slice
var rgb: [u8; 3] = [255, 128, 0]                      // array
var ages: {string: i32} = {"Alice": 30, "Bob": 25}    // map
var primes: {i32} = {2, 3, 5, 7}                      // set
var point: (f64, f64) = (1.0, 2.0)                    // tuple

// Function pointer
fn add(a: i32, b: i32) -> i32 { return a + b }
var #op: fn (i32, i32) -> i32 = add
```

---

The full conversion rules between primitive types are covered in the [Conversion Lattice](/docs/language/conversion-lattice/).

## 5. Literal inference: a separate mechanism

Literals are **untyped** until a type is assigned. Literal typing is not conversion and does not consult this lattice.

1. If an expected type is available from context (annotation, parameter, return position, the other operand of a binop, aggregate element type), the literal takes that type directly, and the compiler checks the value fits. `var b: u8 = 42` is fine. `var b: u8 = 300` is an error at the literal, with the range in the diagnostic.
2. With no expected type, the default is `i32` for integer literals and `f64` for float literals. Only if the value does not fit does the "smallest type that holds it" rule from [Integers](#integers) apply.

Rule 1 comes first on purpose. If promotion fired unconditionally, `var x: u32 = 3000000000` would type the literal as `i64` before looking at the annotation, and then fail to narrow it. Expected-type-first removes that whole class of error.

Suffixed literals (`42u8`) are typed at the literal and then participate in conversion normally.


---

## See also

- [Collections](/docs/language/collections/)
- [Conversion Lattice](/docs/language/conversion-lattice/)
- [Casting](/docs/language/casting/)
- [Implicit Conversions](/docs/language/casting-implicit/)
- [Pointers](/docs/language/pointers/)
- [Type System](/docs/language/type-system/)
- [Calling C/C++](/docs/language/c-cpp-calling/)

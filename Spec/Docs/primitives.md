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
var h = 64usize     // usize: the target's pointer width
var i = 5f32        // f32: a float suffix on an integer body makes it that float
```

The integer suffixes are `i8` `i16` `i32` `i64` `i128`, `u8` `u16` `u32` `u64` `u128`, in lower or upper case (`42U8`), and `usize` and `isize`. A suffix is a declaration, not a hint: `42u8` is a `u8` wherever it stands, so it selects the `u8` overload and a generic called with it deduces `T = u8`. A value that does not fit the suffix's type is an error, and so is a suffix that names no type (`1u7`, [SC074E](/docs/language/diagnostics/)). Prefixes and separators combine with a suffix: `0xFF_FFu16`, `0b1010u8`.

### Overflow behavior

Integer arithmetic wraps around: `+`, `-`, `*`, unary `-`, `~`, `++`, `--`, the shifts and the matching compound assignments compute modulo 2<sup>N</sup> of the operand's type, two's complement, signed or not, in every build. The result has the operand's type, with no promotion: `~x` on a `u8` is a `u8`, and `a * b` on two `u16` values never overflows an `i32` on the way.

```kairo
var a: i32 = 2147483647
var b = a + 1           // -2147483648
var p: u16 = 65535
var q = p * p           // 1
var z: u8 = 0
var n = ~z              // 255
```

A shift count is taken modulo the register width: 32 for types up to 32 bits, else the type's width: with `n` a runtime 33, `1i32 << n` is `2`; with `n` a runtime 9, `1u8 << n` is `0`, since a narrow type shifts in 32 bits and then truncates. A constant count must be below the width. See [Bitwise operators](/docs/language/operators/#bitwise). Division and remainder by zero crash the program (like [`crash!()`](/docs/language/panic/#main-and-crash), not a panic). `MIN / -1` is `MIN` and `MIN % -1` is `0`.

Overflow is never undefined behavior, and the checks cost nothing where the plain operator would not overflow: the compiled code is the same as C++'s for those inputs. Code imported from C or C++ keeps its own rules. Kairo code writing an imported value follows Kairo's: `++` on a C struct's `uint8_t` field, or `+=` on an `int&` returned by a C++ `operator[]`, wraps. A C bit-field wraps at the field's own width.

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
var w = 0x1.8p3f32  // f32 hexadecimal float: 12.0
var b = 1.5bf16     // bf16
```

The float suffixes are `f16`, `bf16`, `f32`, `f64`, `f80` and `f128` (`f80` and `f128` only where the target has them, see below), in lower or upper case. A literal is rounded once, to the type it is used at, from its decimal digits: `16777217.0f32` is `16777216.0` and `16777217.0f64` is exact, and `var q: f128 = 0.1` is `0.1` at `f128` precision, not the `f64` value `0.1` widened. An unknown float suffix (`1.5f8`, `1.5xyz`) is [SC074E](/docs/language/diagnostics/).

Overflow produces `inf`, underflow produces `0.0`. Operations that produce `NaN` (e.g., `0.0 / 0.0`, `sqrt(-1.0)`) propagate `NaN` per IEEE 754 no crash, no trap. Test for `NaN` with `x != x`: a `NaN` compares unequal to everything, itself included, so `x == f64::NAN` is always `false`. An infinity is an ordinary value to compare with: `x == f64::INFINITY`. See [Limits](#limits).

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

### C's `char`: `std::c_char`

`char` is a Unicode scalar value, which C and C++'s `char` is not. C's plain `char` is `std::c_char` (`import std::c_char`): one byte, a third type beside `signed char` (`i8`) and `unsigned char` (`u8`), signed or not as the target's C is. A C++ `char` imports as `c_char`, so a C string is `*const c_char`, which is `const char*` exactly. It is a character, not a number: `as` converts it to and from the integers, it compares with `==` and `<`, it does no arithmetic, and an integer literal takes it only in 0 through 127, where both signednesses agree. In an f-string a `c_char` prints its code, 0 through 255.

```kairo
import std::c_char

var c: c_char = 65          // ok: 'A'
var d = 200u8 as c_char     // the byte 200, whatever the target's char is
// var e: c_char = 200      // error SC075E: only 0 through 127 fit on every target
var n = (c as i32) + 1      // arithmetic on the integer
```

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
| `unsafe *T` | 8 bytes | Raw pointer may hold `&null`, no safety checks |

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

## Limits

Every numeric primitive has a fixed set of associated constants, the Kairo answer to C++'s `std::numeric_limits<T>` and C's `<limits.h>` / `<float.h>`. They are spelled like a class's `eval` members, `Type::NAME`:

```kairo
var lo  = i32::MIN               // -2147483648
var hi  = u8::MAX                // 255
var eps = f64::EPSILON           // 2.220446049250313e-16
var inf = f32::INFINITY
var buf: [u8; u16::MAX as usize + 1]   // a constant: legal in an array length
```

Each one is a constant of its own type, exactly as a suffixed literal is: `u64::MAX` is a `u64` in any context, `var x: u8 = i32::MAX` is the usual narrowing error ([SC028E](/docs/language/diagnostics/)), and `u8::MAX + 1` wraps to `0` like any `u8`. They are constants wherever a constant is needed: an array length, an `eval` binding, `eval if`, a generic value argument. The descriptive ones (`BITS`, `MANTISSA_DIGITS`, the exponents) are `u32` or `i32`, as listed.

### Integers

`u8` through `u128`, `i8` through `i128`, `usize`, `isize`:

| Name | Type | Value |
|---|---|---|
| `MIN` | the type | the smallest value (`0` for unsigned) |
| `MAX` | the type | the largest value |
| `BITS` | `u32` | the width in bits |

`usize` and `isize` take the target's width: `usize::MAX` on a 32-bit target is `4294967295`. `BITS` exists for the 256- and 512-bit integers too; their `MIN` and `MAX` are not supported yet.

### Floating point

`f8e4m3`, `f8e5m2`, `f16`, `bf16`, `f32`, `f64`, `f80`, `f128`:

| Name | Type | Meaning | C++ |
|---|---|---|---|
| `MIN` | the type | most negative finite value (`-MAX`) | `lowest()` |
| `MAX` | the type | largest finite value | `max()` |
| `MIN_POSITIVE` | the type | smallest positive normal value | `min()` |
| `MIN_SUBNORMAL` | the type | smallest positive subnormal value | `denorm_min()` |
| `EPSILON` | the type | the next value after `1.0`, minus `1.0` | `epsilon()` |
| `INFINITY` | the type | positive infinity | `infinity()` |
| `NEG_INFINITY` | the type | negative infinity | `-infinity()` |
| `NAN` | the type | a quiet `NaN` | `quiet_NaN()` |
| `MANTISSA_DIGITS` | `u32` | significand bits, the implicit bit included | `digits` |
| `DIGITS` | `u32` | decimal digits that survive text to float to text | `digits10` |
| `MAX_DIGITS` | `u32` | decimal digits float to text to float needs | `max_digits10` |
| `MIN_EXP` | `i32` | one more than the smallest normal binary exponent | `min_exponent` |
| `MAX_EXP` | `i32` | one more than the largest binary exponent | `max_exponent` |
| `MIN_10_EXP` | `i32` | smallest `n` with `10^n` normal | `min_exponent10` |
| `MAX_10_EXP` | `i32` | largest `n` with `10^n` finite | `max_exponent10` |
| `RADIX` | `u32` | always `2` | `radix` |
| `BITS` | `u32` | storage width in bits | `sizeof(T) * CHAR_BIT` |

> [!WARNING]
> **`MIN` is not C++'s `min()`.** `std::numeric_limits<double>::min()` is the smallest positive normal value. Kairo's `f64::MIN` is the most negative finite value, spelled the same way as `i32::MIN`, so `T::MIN` is the bottom of the range for every numeric type. C++'s `min()` is `MIN_POSITIVE`.

| | `MANTISSA_DIGITS` | `EPSILON` | `MAX` | `MIN_POSITIVE` | `MIN_SUBNORMAL` | `DIGITS` | `MAX_DIGITS` | `MIN_EXP` | `MAX_EXP` | `MIN_10_EXP` | `MAX_10_EXP` |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `f8e4m3` | 4 | 2⁻³ | 448 | 2⁻⁶ | 2⁻⁹ | 0 | 3 | −5 | 9 | −1 | 2 |
| `f8e5m2` | 3 | 2⁻² | 57344 | 2⁻¹⁴ | 2⁻¹⁶ | 0 | 2 | −13 | 16 | −4 | 4 |
| `f16` | 11 | 2⁻¹⁰ | 65504 | 2⁻¹⁴ | 2⁻²⁴ | 3 | 5 | −13 | 16 | −4 | 4 |
| `bf16` | 8 | 2⁻⁷ | ≈3.39·10³⁸ | 2⁻¹²⁶ | 2⁻¹³³ | 2 | 4 | −125 | 128 | −37 | 38 |
| `f32` | 24 | 2⁻²³ | ≈3.40·10³⁸ | 2⁻¹²⁶ | 2⁻¹⁴⁹ | 6 | 9 | −125 | 128 | −37 | 38 |
| `f64` | 53 | 2⁻⁵² | ≈1.80·10³⁰⁸ | 2⁻¹⁰²² | 2⁻¹⁰⁷⁴ | 15 | 17 | −1021 | 1024 | −307 | 308 |
| `f80` | 64 | 2⁻⁶³ | ≈1.19·10⁴⁹³² | 2⁻¹⁶³⁸² | 2⁻¹⁶⁴⁴⁵ | 18 | 21 | −16381 | 16384 | −4931 | 4932 |
| `f128` | 113 | 2⁻¹¹² | ≈1.19·10⁴⁹³² | 2⁻¹⁶³⁸² | 2⁻¹⁶⁴⁹⁴ | 33 | 36 | −16381 | 16384 | −4931 | 4932 |

The values are the formats' own (IEEE 754 for `f16`, `f32`, `f64` and `f128`; bfloat16; x87 extended; OCP FP8 E4M3FN and E5M2), computed by the compiler from each format's layout, never read from the host's `<float.h>`. Every finite one is exact.

Comparing with an infinity works as with any value; comparing with `NAN` never does, because a `NaN` is unequal to everything, itself included:

```kairo
if x == f64::INFINITY { }    // true for +infinity
if x != x { }                // true exactly for a NaN
if x == f64::NAN { }         // always false
```

### Limits a type does not have

A limit a format does not have is not defined, and naming it is an error ([R024E](/docs/language/diagnostics/)), never a substitute value:

- `f8e4m3` is the FN format: it has no infinity, and overflow saturates to 448. `f8e4m3::INFINITY` and `f8e4m3::NEG_INFINITY` are errors; it has a `NAN`.
- `f80` exists only where the target's `long double` is x87 extended. Elsewhere, `f80::MAX` is the same [P003E](/docs/language/diagnostics/) as spelling `f80` at all.
- `f256` and `f512` have no limits until they have a fixed representation.
- The float limits (`EPSILON`, `INFINITY`, ...) are not defined on integers.

### `char`, `byte`, `bool`

| Type | Members |
|---|---|
| `char` | `MIN` = `'\0'`, `MAX` = `'\U0010FFFF'`, `BITS` = 32 |
| `byte` | `BITS` = 8. No `MIN` or `MAX`: a byte is not a number. |
| `bool` | none |

`char::MAX` is the largest Unicode scalar value. The range between `MIN` and `MAX` is not contiguous (the surrogates U+D800 to U+DFFF are not `char`s); the constants name the ends.

> [!NOTE]
> `T::MAX` on a generic parameter `T` is not supported yet.

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
var *p = &x             // *i32
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
var f: fn (i32, i32) -> i32 = add
```

---

The full conversion rules between primitive types are covered in the [Conversion Lattice](/docs/language/conversion-lattice/).

## 5. Literal inference: a separate mechanism

Literals are **untyped** until a type is assigned. Literal typing is not conversion and does not consult this lattice.

1. If an expected type is available from context (annotation, parameter, return position, the other operand of a binop, aggregate element type), the literal takes that type directly, and the compiler checks the value fits. `var b: u8 = 42` is fine. `var b: u8 = 300` is an error at the literal, with the range in the diagnostic. The other operand of a binop gives its type whichever side the literal is on: `1 + b` and `b + 1` are both `u8` additions, and `300 + b` is the same error as `b + 300`. A shift's result is its left operand's type, so a literal on the left of `<<` / `>>` takes the expected type when there is one (`var m: u16 = 1 << n` is a `u16` shift) and otherwise the count's integer type (`1 << 4u8` is a `u8` shift). When both operands are untyped literals, neither gives the other a type and rule 2 applies (`1 << 4` is `i32`).
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

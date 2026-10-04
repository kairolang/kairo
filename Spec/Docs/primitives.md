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

### Extended-width integers (u128-u512, i128-i512)

If the target hardware supports wide registers (e.g., AVX-512), these types map directly to hardware. Otherwise,
the compiler stores them as structs of smaller integers and emits SIMD-accelerated arithmetic when available,
falling back to scalar multi-word operations.

Extended-width integers are always stack-allocated they are value types, not heap-allocated objects.

---

## Floating-Point

All floating-point types except `f80` follow the IEEE 754 standard. The default float type is `f64` if a literal doesn't
fit in `f64`, the compiler promotes to the smallest float type that can hold the value, up to `f512`.

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

Overflow produces `inf`, underflow produces `0.0`. Operations that produce `NaN` (e.g., `0.0 / 0.0`,
`sqrt(-1.0)`) propagate `NaN` per IEEE 754 no crash, no trap. Check for `NaN` explicitly with
`std::is_nan()` when needed.

> [!NOTE]
> `f256` and `f512` are not natively supported on any current hardware and are implemented entirely in software,
> using SIMD instructions when available. Like extended-width integers, they are stack-allocated value types.
> Expect significantly lower performance compared to hardware-backed float types.

### `f80` follows the target's `long double`

`f80` is the x87 80-bit extended format, and it is C's `long double`. It exists only where the target ABI's
`long double` is x87 extended precision. That is a property of the ABI, not the CPU:

| Target | `long double` | `f80` |
|---|---|---|
| x86_64 Linux, BSD, macOS | x87 extended | available |
| i386 Linux | x87 extended | available |
| x86_64 Windows (MSVC) | binary64, despite the x87 hardware | not available |
| x86_64 Android | binary128 | not available |
| AArch64 and RISC-V Linux | binary128 | not available |
| Apple ARM, Windows on ARM | binary64 | not available |

Anywhere else, writing `f80` is an error (P003E). The error names the target and what its `long double` is,
and suggests `f64` where `long double` is binary64 and `f128` where it is binary128. Kairo never silently
substitutes another float type for `f80`.

```kairo
// building for x86_64-unknown-linux-gnu
var x: f80 = 1.0    // ok

// building for aarch64-unknown-linux-gnu
var y: f80 = 1.0    // error P003E: long double is binary128 here; use f128
```

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
| `char` | 4 bytes | Unicode scalar value (U+0000-U+10FFFF) | `char32_t` |

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

`len` counts bytes, not characters; `cp_len` counts codepoints, and `len == cp_len` means the string is
ASCII. A string literal is a borrowed view of static storage: it allocates nothing, and its `cap` is `0`. An
owned string has `cap` bytes of heap memory behind `data`. Both kinds keep a NUL byte after the last byte, so
`data` can be passed to C as a C string.

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
> The stdlib API for strings is still being finalized. Detailed documentation for string methods will be added
> in a future update.

---

## Void

| Type | Size | C++ Equivalent |
|---|---|---|
| `void` | 0 bytes | `void` |

`void` indicates the absence of a value. It can be used as a normal type and as the target of an
`unsafe` pointer (`unsafe *void`), using `void` as a normal type denotes a unit type.

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

`*T` is a thin pointer (8 bytes). It is non-null by construction and supports pointer arithmetic when the compiler can track its provenance via [Tether](/docs/language/tether). See [Pointers](/docs/language/pointers) for full details.

`unsafe *T` is a raw C-style pointer with no compiler tracking. It can be null, and dereferencing a null

`unsafe *T` is undefined behavior. Use `unsafe *T` for [C/C++ interop](/docs/language/c-cpp), custom allocators, and other low-level scenarios. See [Pointers](/docs/language/pointers) and [Unsafe](/docs/language/unsafe) for full details.

```kairo
var x = 42
var p: *i32 = &x                // safe pointer to x
var q: unsafe *i32 = unsafe &x  // raw pointer, no tracking
```

---

## Collections

Collections are built-in generic types with literal syntax. There are three sequence types, which differ in
who owns the elements:

| Type | Name | Owns its elements | Storage |
|---|---|---|---|
| `[T; N]` | Array | yes | `N` elements inline, where the array is |
| `[T;]` | Slice | no | pointer + length over storage owned by something else |
| `[T]` | Vector | yes | a heap copy of its elements |

Maps and sets are heap-allocated.

### Arrays `[T; N]`

A contiguous block of `N` elements stored inline (in the local, the enclosing struct, or the enclosing array).
`N` must be a compile-time constant.

```kairo
var rgb: [u8; 3] = [255, 128, 0]
rgb[0] = 10
// rgb.push(42)  // compile error: fixed size
```

An array is **not a value type**. It cannot be copied, assigned, passed by value, or returned. It can be a
local, a field, or an element of another array; it can be viewed by a slice, pointed to, and passed as a
`const` or `@inout` parameter. Each of the following is a compile error, and each diagnostic names the fix:

```kairo
var a = [1, 2, 3]              // [i32; 3]

var b = a                      // compile error: an array is not copyable
b = a                          // compile error: an array is not assignable
fn f(xs: [i32; 3]) { }         // compile error: takes an array by value
fn g() -> [i32; 3] { }         // compile error: returns an array
```

- To copy, copy the elements, or view the source through a slice or a pointer.
- To assign, assign the elements, or go through a slice.
- To take an array, write `const xs: [i32; 3]` or `@inout xs: [i32; 3]` (both pass by reference), or take a
  slice `[i32;]`.
- To produce one, return a `[T]`, or fill an `@inout` parameter.

```kairo
fn sum(const xs: [i32; 3]) -> i32 { return xs[0] + xs[1] + xs[2] }
fn zero(@inout xs: [i32; 3]) { xs[0] = 0; xs[1] = 0; xs[2] = 0 }

var a = [1, 2, 3]
sum(a)       // 6
zero(&a)     // a is now [0, 0, 0]
```

### Slices `[T;]`

A view over contiguous elements: a pointer and a length. A slice does not own the storage it points into and
never frees it.

```kairo
var s: [i32;] = [1, 2, 3]      // the storage lives as long as s
s[0]                           // 1
```

An array variable does not convert to a slice implicitly yet. Build the slice explicitly from the array.

### Vectors `[T]`

A growable, owning, contiguous array. Layout: `ptr + len + cap` (24 bytes). A vector owns a heap copy of
its elements.

```kairo
var nums: [i32] = [1, 2, 3]
nums.push(4)
nums[0]    // 1 bounds-checked
```

A slice never becomes a vector implicitly, because that allocates. Write the conversion:

```kairo
var s: [i32;] = [1, 2, 3]
var v = s as [i32]             // copies the elements into a new vector
```

### List literals

`[a, b, c]` is an array, `[T; 3]`, unless the context asks for a slice or a vector:

```kairo
var a = [1, 2, 3]              // [i32; 3]
var s: [i32;] = [1, 2, 3]      // slice over storage that lives as long as s
var v: [i32]  = [1, 2, 3]      // vector, owns a copy
f([1, 2, 3])                   // takes the parameter's type: array, slice, or vector
```

The element type is the target's element type. With no target, it is the join of the element types.

An empty `[]` has no element type to infer. Annotate the target as `[T;]` or `[T]`:

```kairo
var e = []                     // compile error: cannot infer the type of an empty list here
var f: [i32] = []              // ok
```

A literal whose element count does not match `[T; N]` is an error. It never falls back to a slice:

```kairo
var x: [i32; 4] = [1, 2, 3]    // compile error: array literal has 3 elements, but '[i32; 4]' needs 4
```

#### How long a slice literal's storage lives

A list literal that becomes a slice is a view of a temporary array. That array lives:

- for the **statement**, when the literal is a function argument;
- for the **enclosing scope**, when the literal directly initializes a `var`.

So a slice literal is an error anywhere the view would outlive its storage:

```kairo
fn make() -> [i32;] {
    return [1, 2]              // compile error: returned from a function
}

var s: [i32;] = [1]
s = [1, 2]                     // compile error: assigned to a slice

struct S {
    var xs: [i32;] = [1]       // compile error: used as a field default
}

var t = S{ xs: [1, 2] }        // compile error: stored in a field
```

The fix is the same in every case: use `[T]` so the elements are owned, or bind the literal to a `var` first
and use that.

> [!WARNING]
> One case is not caught: passing a slice literal to a function that **stores** the slice. The literal's
> storage ends with the statement, and the stored slice then points at nothing. Until [Tether](/docs/language/tether)
> checks this, it is the programmer's responsibility.

#### Slices in fields

A `[T;]` field is a borrowed view; the type holding it does not own the data. A type that keeps its data
declares `[T]` or `[T; N]`:

```kairo
struct Packet {
    var header: [u8; 4]        // owned, inline
    var payload: [u8]          // owned, heap
    var source: [u8;]          // borrowed, must outlive the Packet
}
```

#### Conversions between the three

| From | To | How |
|---|---|---|
| list literal | `[T; N]`, `[T;]`, `[T]` | implicit, when the target asks for it |
| slice `[T;]` | vector `[T]` | explicit only: `s as [T]` (allocates) |
| array variable `[T; N]` | slice `[T;]` | not implicit yet; build the slice explicitly |
| array `[T; N]` | array `[T; N]` | never: arrays are not copyable |

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
var #op: fn (i32, i32) -> i32 = add
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


















# Kairo Primitive Conversion Lattice

Normative specification for implicit and explicit conversions between primitive types.
This document is the single source of truth for `-f[no-]implicit-conv`, overload resolution
ranking, and binary operator result typing.

---

## 1. Conversion classes

Every ordered pair `(S, T)` of primitive types falls into exactly one class:

| Class | Meaning | `as` cast | Implicit |
|---|---|---|---|
| **I** — identity | `S` and `T` are the same type | no-op | yes |
| **W** — implicit | value-preserving for every value of `S`; zero or near-zero cost; target-independent | permitted | yes |
| **E** — explicit | representable but may lose value, sign, or precision, or costs a runtime helper | required | no |
| **U** — unsafe | requires an `unsafe` context in addition to `as` | required | no |
| **X** — forbidden | no cast exists; diagnostic suggests a library function | rejected | no |

I deliberately dropped the "warn" class I floated earlier. A conversion is either
sound-by-construction or it is not; a third state means the checker has to carry a
severity through overload resolution, and severities do not compose. Lossy-cast
detection on known-constant operands belongs in a lint (§8), not in the type relation.

**`-fno-implicit-conv` demotes every W to E.** It changes nothing else. §7 proves this
cannot alter which overload is selected.

---

## 2. The rule set

W membership is decided by five rules. Everything not matched by a rule is E if a
representation-changing cast is meaningful, X otherwise.

**R1 — integer widening.** `uN → uM` and `iN → iM` are W when `M > N`.

**R2 — sign-crossing.** `uN → iM` is W when `M > N` (value-preserving: the entire
unsigned range fits). `iN → uM` is **never** W, for any `N`, `M`. Signed-to-unsigned
loses negatives at every width; there is no widening that repairs it.

**R3 — integer to float.** `S → fM` is W iff every value of `S` is exactly representable
in `fM`, i.e. `bits(S) ≤ mantissa(fM)` counting the implicit leading bit. This is an
*exactness* criterion, not a size criterion — `i32 → f32` is same-size and lossy, while
`i32 → f64` is smaller-to-larger and exact.

| Target | Mantissa bits | Exact integer sources |
|---|---|---|
| `f16` | 11 | `u8`, `i8` |
| `f32` | 24 | `u8`, `i8`, `u16`, `i16` |
| `f64` | 53 | `u8`, `i8`, `u16`, `i16`, `u32`, `i32` |

**R4 — float widening.** `f16 → f32`, `f16 → f64`, `f32 → f64` are W. All other
float-to-float pairs are E.

**R5 — extended width is opaque.** No type wider than 64 bits (`u128`–`u512`,
`i128`–`i512`, `f128`–`f512`) is ever the *target* of a W conversion, and no
extended-width type is ever the *source* of one. Rationale: on targets without wide
register support these conversions emit multi-word or software-SIMD sequences. Making
implicitness depend on the target would mean the same source compiles differently per
triple. Uniform E on all targets keeps the cost visible in the source text and keeps the
lattice target-independent.

Everything else — `bool`, `char`, `byte`, `usize`, `isize`, `string`, `void`, pointers,
aggregates — participates in **no** W conversion in either direction. Reasons in §4.

---

## 3. Core integer table

Rows are source, columns are target. `≤64`-bit fixed-width integers only; wider widths
are E by R5.

| S \ T | `u8` | `u16` | `u32` | `u64` | `i8` | `i16` | `i32` | `i64` |
|---|---|---|---|---|---|---|---|---|
| **`u8`**  | I | W | W | W | E | W | W | W |
| **`u16`** | E | I | W | W | E | E | W | W |
| **`u32`** | E | E | I | W | E | E | E | W |
| **`u64`** | E | E | E | I | E | E | E | E |
| **`i8`**  | E | E | E | E | I | W | W | W |
| **`i16`** | E | E | E | E | E | I | W | W |
| **`i32`** | E | E | E | E | E | E | I | W |
| **`i64`** | E | E | E | E | E | E | E | I |

Read the shape: the unsigned block is upper-triangular, the signed block is
upper-triangular, the unsigned→signed quadrant is *strictly* upper-triangular (one width
step is required, so `u32 → i32` is E), and the signed→unsigned quadrant is empty.

## 3.1 Float and cross-domain

| S \ T | `f16` | `f32` | `f64` | `f128`+ | any int | `bool` | `char` | `byte` |
|---|---|---|---|---|---|---|---|---|
| `u8`/`i8`   | W | W | W | E | see §3 | E | E | E |
| `u16`/`i16` | E | W | W | E | see §3 | E | E | E |
| `u32`/`i32` | E | E | W | E | see §3 | E | E | E |
| `u64`/`i64` | E | E | E | E | see §3 | E | E | E |
| `f16` | I | W | W | E | E | X | X | X |
| `f32` | E | I | W | E | E | X | X | X |
| `f64` | E | E | I | E | E | X | X | X |
| `f128`+ | E | E | E | E/I | E | X | X | X |
| `bool` | X | X | X | X | E | I | X | X |
| `char` | X | X | X | X | E | X | I | X |
| `byte` | X | X | X | X | E | X | X | I |
| `string` | X | X | X | X | X | X | X | X |
| `void` | X | X | X | X | X | X | X | X |

Float→int is E in all cases (truncation toward zero; out-of-range is a saturating
result, not UB — pick this and state it, C's UB here is a permanent source of bugs).

---

## 4. Non-numeric primitives — rationale

**`usize` / `isize`.** No W conversion to or from any fixed-width type, in either
direction, including `usize → u64` on 64-bit targets. This is the one place where a
tempting rule breaks portability outright: if `usize → u64` were W on 64-bit, code would
compile on `x86_64` and fail on `wasm32`. `usize` and `isize` also do not W-convert to
each other. Literals still work — `var i: usize = 0` is literal inference (§5), not
conversion.

**`byte`.** No W conversion to or from `u8`. Your docs restrict `byte` to bitwise ops;
if `byte → u8` were implicit then `b + mask` succeeds by converting both operands and
the restriction is decorative. E in both directions.

**`char`.** `char → u32` is bit-identical and technically widening-free, but a codepoint
is not a number. E. `u32 → char` is E and must range-check (surrogates and `> 0x10FFFF`
are invalid scalar values) — decide whether that check traps or produces a
`char?`/result; do not let an invalid `char` exist.

**`bool`.** E in both directions. Your docs already say "no implicit conversion from
integers"; this extends it to the reverse. `int → bool` is E with `!= 0` semantics.

**Pointers.** `*T → unsafe *T` is **U**, not W — it is a safety downgrade and Tether loses
provenance at that point, so it should be visible. `unsafe *T → *T` is U and must be a
checked or asserted construction, never a silent reinterpretation. `*T → unsafe *void`
is U. Pointer↔integer is U in both directions. No pointer conversion is ever W.

**Aggregates.** Conversions never recurse into structure. `[i32] → [i64]`,
`(i32, i32) → (i64, i64)`, `{string: i32} → {string: i64}` are all X. Function pointers
are invariant in both parameter and return position — no variance, no exceptions. If you
want element-wise conversion it is a library `map`, not a coercion.

---

## 5. Literal inference — a separate mechanism

Literals are **untyped** until a type is assigned. Literal typing is not conversion and
does not consult this lattice.

1. If an expected type is available from context (annotation, parameter, return position,
   the other operand of a binop, aggregate element type), the literal takes that type
   directly, and the compiler checks the value fits. `var b: u8 = 42` — fine. `var b: u8
   = 300` — error at the literal, with the range in the diagnostic.
2. With no expected type, the default is `i32` for integer literals and `f64` for float
   literals. Only if the value does not fit does the "smallest type that holds it" rule
   in your primitives doc apply.

State rule 1 explicitly in the docs, because your current text implies the promotion rule
always fires. Under that reading, `var x = 3000000000` yields `i64`, and a later
`var y: u32 = x` errors even though the value fits `u32` — the type was chosen before
anyone knew the destination. Expected-type-first eliminates the whole class.

Suffixed literals (`42u8`) are typed at the literal and then participate in conversion
normally.

---

## 6. Binary operators

No separate "usual arithmetic conversions." Operator operand unification is defined
*in terms of* the W relation, so there is exactly one conversion concept in the language:

Given operands of type `A` and `B`, `A ≠ B`:

- If `W(A → B)` and not `W(B → A)`: result operand type is `B`.
- If `W(B → A)` and not `W(A → B)`: result operand type is `A`.
- Otherwise: **error**, requiring an explicit cast on one side.

Consequences worth confirming you want:

| Expression | Result | Why |
|---|---|---|
| `i32 + i64` | `i64` | W one way only |
| `u32 + i32` | error | neither direction is W (R2 blocks `i32→u32`; `u32→i32` fails the width test) |
| `u32 + i64` | `i64` | R2 |
| `i32 + f64` | `f64` | R3 |
| `i64 + f64` | error | R3 exactness fails; force the cast |
| `usize + i32` | error | §4 |
| `i64 + i128` | error | R5 — extended width never silent |
| `byte & u8` | error | §4 |

The `u32 + i32` error is the single most valuable line in this document. C's answer is
`u32`, which silently converts every negative `i32` into a huge positive number, and it
has cost the industry more than any other implicit conversion.

Comparison operators use the same unification. Shift operators are the exception: the
right operand is unified independently and any integer type is accepted, since the shift
amount is not in the value domain of the result.

Compound assignment `a op= b` requires `W(typeof(b) → typeof(a))` or an exact match. It
never converts the left operand.

---

## 7. Overload resolution, and why `-fno-implicit-conv` is a strict subset

Conversion sequences have exactly two ranks:

1. **Exact** — I.
2. **Converted** — W.

There is deliberately no ordering *within* rank 2. If two candidates are both reachable
by W, the call is **ambiguous** and errors, even if one conversion is "narrower" in some
intuitive sense. No `i32 → i64` beats `i32 → f64` tiebreaking. No promotion-vs-conversion
distinction. This is the property that makes the flag safe:

> Let `C_on` be the candidate selected with W enabled. `-fno-implicit-conv` demotes every
> W to E, which removes candidates from the viable set but never adds one and never
> reorders the two ranks. An exact-match winner stays the winner. A rank-2 winner becomes
> non-viable, so the call errors. Therefore for all programs: the flag either preserves
> the selection or produces a diagnostic. It can never select a different candidate.

Write that as a differential test: compile the whole suite both ways, diff the
`--dump-type-info` output, and assert every difference is `resolved → error` and never
`resolved(A) → resolved(B)`. If that assertion ever fires you have introduced a ranking
somewhere, and you want to know the day it happens.

### List literal arguments

A list literal argument uses the same two ranks:

- A `[T; N]` parameter, where `N` equals the literal's element count, is **Exact** when every element is
  exact for `T`.
- A `[T;]` or a `[T]` parameter is **Converted**. The two are unordered against each other, like any other
  pair of rank-2 candidates.

```kairo
fn f(const xs: [i32; 3]) { }
fn f(xs: [i32;]) { }
fn f(xs: [i32]) { }

f([1, 2, 3])            // picks [i32; 3]: Exact beats Converted
```

With only the slice and vector overloads, both are Converted and the call is ambiguous. Annotate the
argument to choose:

```kairo
fn g(xs: [i32;]) { }
fn g(xs: [i32]) { }

g([1, 2, 3])            // compile error: call to 'g' is ambiguous
g([1, 2, 3] as [i32])   // ok: vector overload
var s: [i32;] = [1, 2, 3]
g(s)                    // ok: slice overload
```

Literals other than list literals are unaffected.

---

## 8. Lints (not part of the type relation)

- **`lint::lossy-cast`** — an `as` cast where the operand is a known constant that does
  not survive the round trip. Error by default; this is always a bug.
- **`lint::redundant-cast`** — an `as` cast where the pair is I or W.
- **`lint::sign-cast`** — any E cast crossing the signedness boundary. Off by default,
  on under a strict profile.

None of these participate in overload resolution or operand unification.

---

## 9. Invariants — property tests to write now

These are the properties that keep the relation a well-formed partial order. Each is a
one-page property test over the full primitive set, and each catches a class of bug that
is otherwise found by users.

1. **Reflexivity.** `class(T, T) == I` for all `T`.
2. **Antisymmetry.** `W(A → B) ∧ W(B → A) ⟹ A == B`. A W-cycle means overload resolution
   can pick either candidate depending on iteration order.
3. **Transitivity.** `W(A → B) ∧ W(B → C) ⟹ W(A → C)`. The rules in §2 are already
   transitively closed; the test guards against a future rule addition that breaks it.
   If this ever fails, conversion becomes chain-length-dependent and results stop being
   stable under refactoring.
4. **Value preservation.** For every W pair and a generated corpus of source values
   (bounds, zero, ±1 around bounds, random), round-tripping through the target and back
   yields the original. Any failure is a mis-classified cell, not a codegen bug.
5. **Target independence.** The full class matrix is byte-identical across every
   supported triple. `usize`/`isize` rows and columns are the ones this is really
   testing.
6. **Totality.** Every ordered pair over the full primitive set has exactly one class.
   No `default:` fallthrough in the decision function.

---

## 10. Implementation shape

Generate everything from one table. A single `conversions.def` X-macro or TOML listing
`(source, target, class)` for every pair, and from it emit:

- the `ConversionClass classify(TypeId, TypeId)` function used by sema,
- the docs table in this file,
- the property-test corpus for §9,
- the `--dump-type-info` legend.

The alternative — a hand-written `classify` with the docs maintained separately — drifts
within a month, and the drift is invisible because nothing compares them. One source,
three consumers, zero drift.

Order of work: land `classify` and its property tests against the current checker *before*
changing any behavior, so you find out which cells the compiler already disagrees with.
That diff is the actual work item list.
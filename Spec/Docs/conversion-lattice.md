# Kairo Primitive Conversion Lattice

Normative specification for implicit and explicit conversions between primitive types.
This document is the single source of truth for `-f[no-]implicit-conv`, overload resolution
ranking, and binary operator result typing.

---

## 1. Conversion classes

Every ordered pair `(S, T)` of primitive types falls into exactly one class:

| Class | Meaning | `as` cast | Implicit |
|---|---|---|---|
| **I** (identity) | `S` and `T` are the same type | no-op | yes |
| **W** (implicit) | value-preserving for every value of `S`; zero or near-zero cost; target-independent | permitted | yes |
| **E** (explicit) | representable but may lose value, sign, or precision, or costs a runtime helper | required | no |
| **U** (unsafe) | requires an `unsafe` context in addition to `as` | required | no |
| **X** (forbidden) | no cast exists; diagnostic suggests a library function | rejected | no |

There is no "warn" class. A conversion is either sound-by-construction or it is not; a
third state would force the checker to carry a severity through overload resolution, and
severities do not compose. Lossy-cast detection on known-constant operands is a lint (section 8),
not part of the type relation.

**`-fno-implicit-conv` demotes every W to E.** It changes nothing else. Section 7 proves this
cannot alter which overload is selected.

---

## 2. The rule set

W membership is decided by five rules. Everything not matched by a rule is E if a
representation-changing cast is meaningful, X otherwise.

**R1 - integer widening.** `uN -> uM` and `iN -> iM` are W when `M > N`.

**R2 - sign-crossing.** `uN -> iM` is W when `M > N` (value-preserving: the entire
unsigned range fits). `iN -> uM` is **never** W, for any `N`, `M`. Signed-to-unsigned
loses negatives at every width; there is no widening that repairs it.

**R3 - integer to float.** `S -> fM` is W iff every value of `S` is exactly representable
in `fM`, i.e. `bits(S) <= mantissa(fM)` counting the implicit leading bit. This is an
*exactness* criterion, not a size criterion: `i32 -> f32` is same-size and lossy, while
`i32 -> f64` is smaller-to-larger and exact.

| Target | Mantissa bits | Exact integer sources |
|---|---|---|
| `f16` | 11 | `u8`, `i8` |
| `f32` | 24 | `u8`, `i8`, `u16`, `i16` |
| `f64` | 53 | `u8`, `i8`, `u16`, `i16`, `u32`, `i32` |

**R4 - float widening.** `f16 -> f32`, `f16 -> f64`, `f32 -> f64` are W. All other
float-to-float pairs are E.

**R5 - extended width is opaque.** No type wider than 64 bits (`u128`-`u512`,
`i128`-`i512`, `f128`-`f512`) is ever the *target* of a W conversion, and no
extended-width type is ever the *source* of one. Rationale: on targets without wide
register support these conversions emit multi-word or software-SIMD sequences. Making
implicitness depend on the target would mean the same source compiles differently per
triple. Uniform E on all targets keeps the cost visible in the source text and keeps the
lattice target-independent.

Everything else (`bool`, `char`, `byte`, `usize`, `isize`, `string`, `void`, pointers,
aggregates) participates in **no** W conversion in either direction. Reasons in section 4.
The single exception is an argument to an [imported C/C++ function](/docs/language/c-cpp-calling/#argument-conversions), where
`usize`/`isize` widen by the boundary rule in section 4.1.

---

## 3. Core integer table

Rows are source, columns are target. `<=64`-bit fixed-width integers only; wider widths
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
upper-triangular, the unsigned-to-signed quadrant is *strictly* upper-triangular (one width
step is required, so `u32 -> i32` is E), and the signed-to-unsigned quadrant is empty.

## 3.1 Float and cross-domain

| S \ T | `f16` | `f32` | `f64` | `f128`+ | any int | `bool` | `char` | `byte` |
|---|---|---|---|---|---|---|---|---|
| `u8`/`i8`   | W | W | W | E | see section 3 | E | E | E |
| `u16`/`i16` | E | W | W | E | see section 3 | E | E | E |
| `u32`/`i32` | E | E | W | E | see section 3 | E | E | E |
| `u64`/`i64` | E | E | E | E | see section 3 | E | E | E |
| `f16` | I | W | W | E | E | X | X | X |
| `f32` | E | I | W | E | E | X | X | X |
| `f64` | E | E | I | E | E | X | X | X |
| `f128`+ | E | E | E | E/I | E | X | X | X |
| `bool` | X | X | X | X | E | I | X | X |
| `char` | X | X | X | X | E | X | I | X |
| `byte` | X | X | X | X | E | X | X | I |
| `string` | X | X | X | X | X | X | X | X |
| `void` | X | X | X | X | X | X | X | X |

Float-to-int is E in all cases. The cast truncates toward zero and saturates on
out-of-range values; it is never undefined behavior. See
[Casting](/docs/language/casting/#float-to-integer).

---

## 4. Non-numeric primitives: rationale

**`usize` / `isize`.** No W conversion to or from any fixed-width type, in either
direction, including `usize -> u64` on 64-bit targets. This is the one place where a
tempting rule breaks portability outright: if `usize -> u64` were W on 64-bit, code would
compile on `x86_64` and fail on `wasm32`. `usize` and `isize` also do not W-convert to
each other. Literals still work: `var i: usize = 0` is literal inference (section 5), not
conversion.

**`byte`.** No W conversion to or from `u8`. `byte` is restricted to bitwise operations
([Byte](/docs/language/primitives/#byte)); if `byte -> u8` were implicit then `b + mask` would succeed by converting
both operands and the restriction would be decorative. E in both directions.

**`char`.** `char -> u32` is bit-identical and technically widening-free, but a codepoint
is not a number. E. `u32 -> char` is E and range-checks: surrogates and values above
`0x10FFFF` are not scalar values, and an invalid `char` never exists. Whether the failed
check traps or yields a `char?` is not yet specified.

**`bool`.** E in both directions. [Bool](/docs/language/primitives/#bool) already forbids implicit conversion
from integers; the reverse is forbidden too. `int -> bool` is E with `!= 0` semantics.

**Pointers.** `*T -> unsafe *T` is **U**, not W. It is a safety downgrade and [Tether](/docs/language/tether-bounds/#provenance-and-epochs) loses
provenance at that point, so it should be visible. `unsafe *T -> *T` is U and must be a
checked or asserted construction, never a silent reinterpretation. `*T -> unsafe *void`
is U. Pointer-to-integer and integer-to-pointer are both U. No pointer conversion is ever W.

**Aggregates.** Conversions never recurse into structure. `[i32] -> [i64]`,
`(i32, i32) -> (i64, i64)`, `{string: i32} -> {string: i64}` are all X. [Function pointers](/docs/language/functions/#function-pointers)
are invariant in both parameter and return position: no variance, no exceptions. If you
want element-wise conversion it is a library `map`, not a coercion.

### 4.1 The C/C++ boundary

An argument to an **imported** C/C++ function may widen to or from `usize`/`isize`
without `as`. Nothing else uses this rule: Kairo functions, assignments, `if`/`match`
arms and operator operands keep section 4 alone.

The rule reads the target only below 32 bits. `usize` and `isize` are taken as
[32, 64] bits wide, or [P, 64] on a target whose pointer width P is below 32; a
fixed-width integer of N bits is [N, N]. `S -> D` is implicit iff:

- same signedness: `max(S) <= min(D)`
- unsigned to signed: `max(S) < min(D)`
- signed to unsigned: never

| Accepted | Refused |
|---|---|
| `u8`/`u16`/`u32` -> `usize` | `u64` -> `usize` (narrows on 32-bit) |
| `i8`/`i16`/`i32` -> `isize` | `i64` -> `isize` (narrows on 32-bit) |
| `u8`/`u16` -> `isize` | `u32` -> `isize` (same width on 32-bit) |
| `usize` -> `u64`, `isize` -> `i64` | `usize` -> `u32`, `isize` -> `i32` (narrow on 64-bit) |
| | `usize` -> `i64` (same width on 64-bit) |
| | `i32` -> `usize`, `isize` -> `u64` (signed to unsigned) |

Because the rule judges against the narrowest and widest target at once, every 32- and
64-bit target accepts the same set of programs; a 16-bit target accepts a subset. This
keeps the property section 4 protects. A conversion accepted by this rule is considered only
when section 3 would require `as`, and ranks like any other implicit conversion in overload
resolution. Extended-width types (R5), floats and
non-numeric types never take it, and `-fno-implicit-conv` turns it off like any other W.

The importer reads `size_t`/`uintptr_t` as `usize`, and `ptrdiff_t`/`intptr_t`/`ssize_t`
as `isize`. A plain `unsigned long` stays a fixed-width type (`u64` on LP64 targets) and
is judged by section 3.

---

Literal inference is covered in [Primitives](/docs/language/primitives/#5-literal-inference-a-separate-mechanism).

---

## 6. Binary operators

No separate "usual arithmetic conversions." Operator operand unification is defined
*in terms of* the W relation, so there is exactly one conversion concept in the language:

Given operands of type `A` and `B`, `A != B`:

- If `W(A -> B)` and not `W(B -> A)`: result operand type is `B`.
- If `W(B -> A)` and not `W(A -> B)`: result operand type is `A`.
- Otherwise: **error**, requiring an explicit cast on one side.

Consequences:

| Expression | Result | Why |
|---|---|---|
| `i32 + i64` | `i64` | W one way only |
| `u32 + i32` | error | neither direction is W (R2 blocks `i32 -> u32`; `u32 -> i32` fails the width test) |
| `u32 + i64` | `i64` | R2 |
| `i32 + f64` | `f64` | R3 |
| `i64 + f64` | error | R3 exactness fails; force the cast |
| `usize + i32` | error | section 4 |
| `i64 + i128` | error | R5: extended width never silent |
| `byte & u8` | error | section 4 |

The `u32 + i32` error is deliberate. C's answer is `u32`, which silently converts every
negative `i32` into a huge positive number; Kairo refuses rather than guess.

Comparison operators use the same unification. Shift operators are the exception: the
right operand is unified independently and any integer type is accepted, since the shift
amount is not in the value domain of the result.

[Compound assignment](/docs/language/operators/#assignment) `a op= b` requires `W(typeof(b) -> typeof(a))` or an exact match. It
never converts the left operand.

---

## 7. Overload resolution, and why `-fno-implicit-conv` is a strict subset

Conversion sequences have exactly two ranks:

1. **Exact** (I).
2. **Converted** (W).

There is deliberately no ordering *within* rank 2. If two candidates are both reachable
by W, the call is **ambiguous** and errors, even if one conversion is "narrower" in some
intuitive sense. No `i32 -> i64` beats `i32 -> f64` tiebreaking. No promotion-vs-conversion
distinction. The tie-breaks in [Function Overloading](/docs/language/functions-overloading/)
(reference binding, non-generic over generic, most specialized generic) never order conversions, so "no
ordering within rank 2" still holds, and so does the guarantee below. This is the property that makes the
flag safe:

> Let `C_on` be the candidate selected with W enabled. `-fno-implicit-conv` demotes every
> W to E, which removes candidates from the viable set but never adds one and never
> reorders the two ranks. An exact-match winner stays the winner. A rank-2 winner becomes
> non-viable, so the call errors. Therefore for all programs: the flag either preserves
> the selection or produces a diagnostic. It can never select a different candidate.

### List literal arguments

A [list literal](/docs/language/collections/#list-literals) argument uses the same two ranks:

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

- **`lint::lossy-cast`**: an `as` cast where the operand is a known constant that does
  not survive the round trip. Error by default; this is always a bug.
- **`lint::redundant-cast`**: an `as` cast where the pair is I or W.
- **`lint::sign-cast`**: any E cast crossing the signedness boundary. Off by default,
  on under a strict profile.

None of these participate in overload resolution or operand unification.

---

## See also

- [Casting](/docs/language/casting/)
- [Implicit Conversions](/docs/language/casting-implicit/)
- [Primitives](/docs/language/primitives/)
- [Collections](/docs/language/collections/)
- [Functions](/docs/language/functions/)
- [Operators](/docs/language/operators/)
- [Function Overloading](/docs/language/functions-overloading/)
- [Calling C/C++](/docs/language/c-cpp-calling/#argument-conversions)

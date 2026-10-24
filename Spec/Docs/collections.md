# Collections

Collections are built-in generic types with literal syntax. There are three sequence types, which differ in who owns the elements:

| Type | Name | Owns its elements | Storage |
|---|---|---|---|
| `[T; N]` | Array | yes | `N` elements inline, where the array is |
| `[T;]` | Slice | no | pointer + length over storage owned by something else |
| `[T]` | Vector | yes | a heap copy of its elements |

Maps and sets are heap-allocated.

## Arrays `[T; N]`

A contiguous block of `N` elements stored inline (in the local, the enclosing struct, or the enclosing array). `N` must be a compile-time constant.

```kairo
var rgb: [u8; 3] = [255, 128, 0]
rgb[0] = 10
// rgb.push(42)  // compile error: fixed size
```

An array is **not a value type**. It cannot be copied, assigned, passed by value, or returned. It can be a local, a field, or an element of another array; it can be viewed by a slice, pointed to, and passed as a `const` or [`@inout` parameter](/docs/language/functions-parameter-modes/). Each of the following is a compile error, and each diagnostic names the fix:

```kairo
var a = [1, 2, 3]              // [i32; 3]

var b = a                      // compile error: an array is not copyable
b = a                          // compile error: an array is not assignable
fn f(xs: [i32; 3]) { }         // compile error: takes an array by value
fn g() -> [i32; 3] { }         // compile error: returns an array
```

- To copy, copy the elements, or view the source through a slice or a pointer.
- To assign, assign the elements, or go through a slice.
- To take an array, write `const xs: [i32; 3]` or `@inout xs: [i32; 3]` (both pass by reference), or take a slice `[i32;]`.
- To produce one, return a `[T]`, or fill an `@inout` parameter.

```kairo
fn sum(const xs: [i32; 3]) -> i32 { return xs[0] + xs[1] + xs[2] }
fn zero(@inout xs: [i32; 3]) { xs[0] = 0; xs[1] = 0; xs[2] = 0 }

var a = [1, 2, 3]
sum(a)       // 6
zero(&a)     // a is now [0, 0, 0]
```

Indexing an array with a range, `a[i..j]`, gives a slice over those elements:

```kairo
var a = [1, 2, 3, 4]
var mid = a[1..3]    // [i32;] viewing a[1] and a[2]
```

## Slices `[T;]`

A view over contiguous elements: a pointer and a length. A slice does not own the storage it points into and never frees it.

```kairo
var s: [i32;] = [1, 2, 3]      // the storage lives as long as s
s[0]                           // 1
```

An array converts to a slice implicitly. The slice is a view of the array, so nothing is copied. A `const` array converts only to `[const T;]`. A vector also converts to a slice implicitly.

```kairo
fn total(xs: [i32;]) -> i32 { ... }

var a = [1, 2, 3]
total(a)                       // a viewed as [i32;]
```

## Vectors `[T]`

A growable, owning, contiguous array. Layout: `ptr + len + cap` (24 bytes). A vector owns a heap copy of its elements.

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

## List literals

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

### How long a slice literal's storage lives

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

The fix is the same in every case: use `[T]` so the elements are owned, or bind the literal to a `var` first and use that.

> [!WARNING]
> One case is not caught: passing a slice literal to a function that **stores** the slice. The literal's storage ends with the statement, and the stored slice then points at nothing. Until [Tether](/docs/language/tether/) checks this, it is the programmer's responsibility.

### Slices in fields

A `[T;]` field is a borrowed view; the type holding it does not own the data. A type that keeps its data declares `[T]` or `[T; N]`:

```kairo
struct Packet {
    var header: [u8; 4]        // owned, inline
    var payload: [u8]          // owned, heap
    var source: [u8;]          // borrowed, must outlive the Packet
}
```

### Conversions between the three

| From | To | How |
|---|---|---|
| list literal | `[T; N]`, `[T;]`, `[T]` | implicit, when the target asks for it |
| slice `[T;]` | vector `[T]` | explicit only: `s as [T]` (allocates) |
| array `[T; N]` | slice `[T;]` | implicit, a view (no copy); a `const` array only to `[const T;]` |
| vector `[T]` | slice `[T;]` | implicit, a view (no copy) |
| array `[T; N]` | array `[T; N]` | never: arrays are not copyable |

## Maps `{K: V}`

A hash map from keys of type `K` to values of type `V`.

```kairo
var ages: {string: i32} = {"Alice": 30, "Bob": 25}
ages["Charlie"] = 35
```

## Sets `{T}`

A hash set of unique elements.

```kairo
var primes: {i32} = {2, 3, 5, 7, 11}
```

## Tuples `(T1, T2, ...)`

A fixed-size, heterogeneous, ordered group of values. Stored contiguously with padding for alignment.

```kairo
var point: (f64, f64) = (1.0, 2.0)
var record: (i32, string, bool) = (42, "Answer", true)
```

## Function Pointers `fn (T1, T2, ...) -> R`

[A pointer to a function](/docs/language/functions/#function-pointers) with the given signature. Platform-dependent size.

```kairo
fn add(a: i32, b: i32) -> i32 { return a + b }
var #op: fn (i32, i32) -> i32 = add
op(3, 4)  // 7
```

> [!IMPORTANT]
> The stdlib API for vectors, maps, and sets is still being finalized. Detailed method documentation will be added in a future update.

---

## See also

- [Primitives](/docs/language/primitives/)
- [Conversion Lattice](/docs/language/conversion-lattice/#list-literal-arguments)
- [Casting](/docs/language/casting/)
- [Pointers](/docs/language/pointers/)
- [Tether](/docs/language/tether/)
- [Type System](/docs/language/type-system/)
- [Destructuring](/docs/language/variables/#destructuring)
- [Parameter Modes](/docs/language/functions-parameter-modes/)

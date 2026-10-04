# Diagnostics

This page lists compiler error messages verbatim so they can be searched. Placeholders are written in braces:
`{n}` is a number, `{x}` a parameter name, `{f}` a function name, and `[T; M]` the type as written in your code.

---

## List Literals

### `array literal has {n} element(s), but '[T; M]' needs {m}`

A list literal initializes a fixed array of a different length. The literal is not silently turned into a
slice.

```kairo
var x: [i32; 4] = [1, 2, 3]    // error: array literal has 3 element(s), but '[i32; 4]' needs 4
```

**Fix:** give the literal the right number of elements, or change the target to `[T;]` or `[T]`.

### `cannot infer the type of an empty list here; annotate the target as '[T;]' or '[T]'`

`[]` has no elements to take a type from and no target to take one from.

```kairo
var e = []                     // error
var f: [i32] = []              // ok
```

**Fix:** annotate the target.

---

## Slice Literal Lifetime

A list literal that becomes a slice `[T;]` is a view of a temporary array. These errors report the positions
where the view would outlive that array. See
[Primitives](/docs/language/primitives#how-long-a-slice-literals-storage-lives).

### `a list literal returned from a function is a view of a temporary array and would outlive it; use '[T]' to own the elements, or bind the literal to a 'var' first`

```kairo
fn make() -> [i32;] {
    return [1, 2]              // error
}
```

### `a list literal assigned to a slice is a view of a temporary array and would outlive it; use '[T]' to own the elements, or bind the literal to a 'var' first`

```kairo
var s: [i32;] = [1]
s = [1, 2]                     // error
```

### `a list literal used as a field default is a view of a temporary array and would outlive it; use '[T]' to own the elements, or bind the literal to a 'var' first`

```kairo
struct S {
    var xs: [i32;] = [1]       // error
}
```

### `a list literal stored in a field is a view of a temporary array and would outlive it; use '[T]' to own the elements, or bind the literal to a 'var' first`

```kairo
var t = S{ xs: [1, 2] }        // error
```

**Fix, for all four:** declare the target `[T]` so it owns its elements, or bind the literal to a `var` in a
scope that outlives the slice and use that variable.

> [!NOTE]
> Passing a slice literal to a function that stores the slice is not diagnosed. Until
> [Tether](/docs/language/tether) checks it, it is the programmer's responsibility.

---

## Arrays

A fixed array `[T; N]` is not a value type. See [Primitives](/docs/language/primitives#arrays-t-n).

### `an array is not copyable; initialize it from a list literal, or view the source through a slice or a pointer`

```kairo
var a = [1, 2, 3]
var b = a                      // error
```

### `an array is not assignable; assign its elements, or go through a slice`

```kairo
var a = [1, 2, 3]
var b = [4, 5, 6]
b = a                          // error
```

### `parameter '{x}' takes an array by value; write 'const', '@inout', or take a slice`

```kairo
fn f(xs: [i32; 3]) { }         // error
fn f(const xs: [i32; 3]) { }   // ok
fn f(@inout xs: [i32; 3]) { }  // ok
fn f(xs: [i32;]) { }           // ok
```

### `'{f}' returns an array; an array is not returned by value, return '[T]' or fill an '@inout' parameter`

```kairo
fn g() -> [i32; 3] { ... }     // error
fn g() -> [i32] { ... }        // ok
fn g(@inout out: [i32; 3]) { } // ok
```

---

## Overload Resolution

### `call to '{f}' is ambiguous: more than one candidate matches at the same rank`

Two or more overloads are viable and neither is an exact match, so there is nothing to choose between them.
Conversions are not ranked against each other.

```kairo
fn f(xs: [i32;]) { }
fn f(xs: [i32]) { }

f([1, 2, 3])                   // error: call to 'f' is ambiguous
f([1, 2, 3] as [i32])          // ok
```

**Fix:** make the argument's type explicit with `as` or a typed local. See
[Primitives](/docs/language/primitives#list-literal-arguments).

---

## Default Arguments

### SC106E: a default argument refers to another parameter or `self`

A default is evaluated with no access to the call's other arguments, so it cannot name them.

```kairo
fn a(x: i32, y: i32 = x) { }          // error SC106E
fn m(self, y: i32 = self.v) { }       // error SC106E
```

**Fix:** add an overload that leaves the parameter out and forwards the value. See
[Functions](/docs/language/functions#a-default-stands-alone).

### SC107E: a named argument skips a defaulted parameter of an imported C++ function

C++ applies an imported function's defaults and can only leave out trailing arguments. A call that names a
later parameter while an earlier defaulted one is omitted cannot be expressed.

```kairo
// C++: void blit(int x, int y = 0, int scale = 1);
blit(4, scale: 2)            // error SC107E
```

**Fix:** pass the earlier arguments explicitly: `blit(4, y: 0, scale: 2)`. See
[Functions](/docs/language/functions#defaults-on-imported-c-functions).

---

## Lifecycle

### SC110E: a constructor has the shape of a transfer constructor but is not declared as one

A constructor that takes `Self` first and defaults every later parameter is a transfer constructor, and is
written only as `@copy fn X(self, const other: Self)` or `@move fn X(self, other: Self)`.

```kairo
fn X(self, other: Self) { }               // error SC110E: no marker
fn X(self, @move other: Self) { }         // error SC110E: a mode on the parameter
fn X(self, other: Self, k: i32 = 0) { }   // error SC110E: a defaulted extra parameter
```

**Fix:** put `@copy` or `@move` on the constructor and write the parameter bare. See
[Classes](/docs/language/classes#the-transfer-constructor).

---

## Generators

### SC111E: `yield` where nothing can yield

`yield` is allowed only in a function declared `-> yield T`. It is an error outside a function, inside a
closure, or in a function with any other return type.

```kairo
fn count() -> i32 {
    yield 1          // error SC111E
    return 0
}
```

**Fix:** declare the function `-> yield T`, or remove the `yield`. See
[Generators](/docs/language/functions#generators).

### SC112E: this kind of function cannot be a generator

`main`, constructors, destructors (`op delete`), `eval` functions, C-variadic functions, and functions
returning `!` cannot be declared `-> yield T`.

```kairo
fn main() -> yield i32 { }   // error SC112E
```

**Fix:** move the sequence into a separate `-> yield T` function and call it from here.

---

## Portability

### P003E: a primitive type is not available on the target

`f80` exists only where the target ABI's `long double` is x87 extended precision. The error names the target
and what its `long double` is.

**Fix:** use `f64` where `long double` is binary64, or `f128` where it is binary128. See
[Primitives](/docs/language/primitives#f80-follows-the-targets-long-double).

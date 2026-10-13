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

### P007E: bundled sysroot for the target is malformed

A `--target` matched a folder under `<prefix>/sysroot/`, but the folder is not a directory, has no
`SYSROOT.toml`, or the manifest does not parse. A note says which.

**Fix:** restore the manifest by re-extracting the sysroot, or remove the folder to fall back to `--sysroot`.
See [Cross-compilation](/docs/language/c-cpp#cross-compilation).

---

## Value Arms

The value forms of `if`, `match`, and `try`. See
[Control Flow](/docs/language/control-flow#if-as-an-expression-ternary-equivalent).

### S073E: braced value arm in an 'if', 'try' or 'match' expression

Messages:

- `value arms are written '=> expr'; '{ }' arms are statement-only`

#### value arms are written '=> expr'

the expression forms of `if`, `try` and `match` give each arm its value with `=>`. a `{ }`
after a control keyword is always a statement block, so braces cannot hold an arm's value.
`=>` introduces exactly one value expression.

##### example

```kairo
var z = if a == b { 2 } else { 0 }                  // error
var n = try { parse(s) } catch { 0 }                // error
var k = match s { case 2 { x + y } default { 0 } }  // error
```

##### how to fix

replace each `{` with `=>` and drop its `}`; the fix-it does this when the braces hold a
single expression:

```kairo
var z = if a == b => 2 else => 0
var n = try parse(s) catch => 0
var k = match s {
    case 2 => x + y
    default => 0
}
```

an arm that needs several statements belongs in the statement form (`if c { ... }`, a
statement-form `match`), or in a `({ ... })` statement expression. to `try` a brace
expression such as a set literal, parenthesize it: `try ({1, 2}) catch => {}`.

### S074E: expected '=>' before a value arm

Messages:

- `expected '=>' after condition`
- `expected '=>' after 'else'`
- `expected '=>' after pattern`
- `expected '=>' after catch arm`

#### expected '=>'

in the expression forms of `if`, `try` and `match`, the condition, the `else`, the case
pattern and the catch arm are each followed by `=>` and then the arm's value.

##### example

```kairo
var z = if c 1 else => 2      // missing '=>' after the condition
var z = if c => 1 else 2      // missing '=>' after 'else'
```

##### how to fix

insert `=>` where the fix-it points: `var z = if c => 1 else => 2`.

### S075E: match arms mix '=>' and '{ }' forms

Messages:

- `match arms mix '=>' and '{ }' forms`

#### match arms mix '=>' and '{ }' forms

a `match` in statement position is either a statement (every arm is a `{ }` block) or a
value (every arm is `=> expr`). an arm of each kind in one `match` is neither.

##### example

```kairo
match s {
    case 1 { f() }
    default => g()     // the other arms are blocks
}
```

##### how to fix

pick one form for every arm: `default { g() }` for a statement match, or `case 1 => f()`
for a value match.

### S076E: match arms separated by a comma

Messages:

- `match arms are not separated by ','`

#### match arms are not separated by ','

the arms of a `match` follow each other directly; a value arm ends where its expression
does. a `,` after an arm (the Rust spelling) is not part of the grammar.

##### example

```kairo
var k = match s {
    case 1 => a,       // error
    default => b
}
```

##### how to fix

delete the comma.

### S077E: nested 'if' or 'try' expression must be parenthesized

Messages:

- `an 'if' expression here must be parenthesized`
- `a 'try' expression here must be parenthesized`

#### nested 'if' or 'try' expression must be parenthesized

the last arm of an `if` or `try` expression runs to the end of the surrounding
expression. where such an expression sits in front of more of the enclosing construct,
it is ambiguous to the reader which construct the following `else`, `=>` or `catch`
belongs to, so it must be parenthesized. the positions are:

- the `then` arm, or an `else if` arm, of an `if` expression
- the condition of an `if` or `else if`
- a `where` guard
- the operand of a `try` expression, or any catch arm except the last
- a `match` scrutinee

##### example

```kairo
var z = if a => if b => 1 else => 2 else => 3      // error
var n = try try f() catch => 1 catch => 2          // error
```

##### how to fix

parenthesize the inner expression:

```kairo
var z = if a => (if b => 1 else => 2) else => 3
var n = try (try f() catch => 1) catch => 2
```

an inner `try` takes every `catch` that follows it, so in `try try f() ...` the outer
`try` is left without arms and the intended split cannot be recovered; no fix-it is
offered there. parenthesize the inner `try` together with its own arms.

an `if` or `try` needs no parentheses as the final `else` arm, the final catch arm, a
match arm value, a whole initializer, a call argument or a return value.

### S078W: 'if' or 'try' expression as an operator's operand

Messages:

- `this 'if' expression extends to the end of the expression`
- `this 'try' expression extends to the end of the expression`

#### this 'if'/'try' expression extends to the end of the expression

the last arm of an `if` or `try` expression takes everything up to the end of the
surrounding expression. as the right operand of a binary operator, or the operand of a
prefix operator, that is easy to misread:

```kairo
var z = x + if c => 1 else => 2 + 5     // x + (if c => 1 else => (2 + 5))
```

the parse is well-defined; the warning is only about readability. assignment operators
and variable initializers are exempt, since their right side runs to the end of the
expression anyway.

##### how to fix

parenthesize the `if` or `try`: `x + (if c => 1 else => 2) + 5`.

### S079W: '=>' between 'else' and 'if' is redundant

Messages:

- `write 'else if'`

#### write 'else if'

`else => if c => a else => b` and `else if c => a else => b` parse to the same thing, an
`if` expression whose final arm is another `if`. only `else if` is idiomatic.

##### how to fix

delete the `=>`; the fix-it does this. to keep a nested `if` as the final arm on purpose,
parenthesize it: `else => (if c => a else => b)`.

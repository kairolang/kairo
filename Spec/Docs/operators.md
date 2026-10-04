# Operators

Kairo's operators follow C-style precedence and semantics with a few additions: exponentiation (`^^`), null-aware
equality (`===`), null-safe access (`?.`, `?->`), and ranges (`..`, `..=`). Most operators can be overloaded
for user-defined types; the [overload table](#all-overload-able-operators-for-user-defined-types) lists which.

---

## Arithmetic

| Operator | Description | Example |
|---|---|---|
| `+` | Addition / unary plus | `a + b`, `+a` |
| `-` | Subtraction / unary negation | `a - b`, `-a` |
| `*` | Multiplication | `a * b` |
| `/` | Division | `a / b` |
| `%` | Modulo (remainder) | `a % b` |
| `^^` | Exponentiation | `2 ^^ 8` -> 256 |

Integer division truncates toward zero, matching C++.

The base of `^^` takes the expected type, the exponent may be any integer type, and the result has the base's
type (`u64 ^^ u8` is `u64`, `f64 ^^ i32` is `f64`). A float exponent is an error.

- `x ^^ 0` is `1`.
- A negative exponent is `(1 / x) ^^ n` using the base type's own division. For an integer base that is
  `0`, `1` or `-1`; for a float base it is the reciprocal.
- Overflow behaves exactly as repeated `*` does; see below.

```kairo
var a = 2 ^^ 10       // 1024
var b = 2.0 ^^ -2     // 0.25
var c = 2 ^^ -1       // 0: 1 / 2 is 0 for an integer
var d = 2 ^^ 0.5      // error: the exponent must be an integer
```

### Integer overflow

Unsigned overflow wraps around (modular arithmetic). Signed overflow depends on the build mode:

- **Debug:** crashes with a diagnostic.
- **Release:** wraps around silently.

See [Primitives](/docs/language/primitives) for full details on numeric type behavior.

### Floating-point overflow

Overflow produces `inf`, underflow produces `0.0`. Operations that produce `NaN` (e.g., `0.0 / 0.0`,
`sqrt(-1.0)`) propagate `NaN` per IEEE 754 no crash, no trap. Check explicitly with `std::is_nan()`.

---

## Comparison

| Operator | Description | Example |
|---|---|---|
| `==` | Equality | `a == b` |
| `!=` | Inequality | `a != b` |
| `<` | Less than | `a < b` |
| `>` | Greater than | `a > b` |
| `<=` | Less than or equal | `a <= b` |
| `>=` | Greater than or equal | `a >= b` |
| `<=>` | Three-way comparison (spaceship) | `a <=> b` |
| `===` | Null-aware equality | `a === b` |

`<=>` returns an `Ordering`, matching the C++20 spaceship operator.

### `==` vs `===`

`===` is valid when at least one operand is nullable (`T?`). `a === b` is true when both are non-null and
equal. On nullable pointers (`*T?`) it compares the values they point to, where `==` compares **addresses**.
Using `===` where neither operand is nullable is an error, including two `*T`. To compare the pointees of two
non-null pointers, dereference them and use `==`.

```kairo
var a = 42
var b = 42
var p: *i32? = &a
var q: *i32? = &b

p == q    // false: different addresses
p === q   // true: both point to 42
```

```kairo
var x = &a
var y = &b

x === y   // error: '===' needs a nullable operand; '*i32' and '*i32' are not nullable
*x == *y  // true
```

`===` is not overloadable.

---

## Logical

| Operator | Description | Example |
|---|---|---|
| `&&` | Logical AND | `a && b` |
| `\|\|` | Logical OR | `a \|\| b` |
| `!` | Logical NOT | `!a` |

Short-circuit evaluation applies: `&&` does not evaluate the right operand if the left is `false`, and `||`
does not evaluate the right operand if the left is `true`. This is identical to C++.

---

## Bitwise

| Operator | Description | Example |
|---|---|---|
| `&` | Bitwise AND | `a & b` |
| `\|` | Bitwise OR | `a \| b` |
| `^` | Bitwise XOR | `a ^ b` |
| `~` | Bitwise NOT (complement) | `~a` |
| `<<` | Left shift | `a << 2` |
| `>>` | Right shift | `a >> 2` |

Right shift is arithmetic (sign-extending) for signed types and logical (zero-filling) for unsigned types.

---

## Assignment

| Operator | Description |
|---|---|
| `=` | Assignment |
| `+=`, `-=`, `*=`, `/=`, `%=` | Arithmetic compound assignment |
| `&=`, `\|=`, `^=` | Bitwise compound assignment |
| `<<=`, `>>=` | Shift compound assignment |

On primitives, `x op= y` behaves like `x = x op y` with `x` evaluated once. For user-defined types, a
compound assignment and its binary operator form one pair (`+=` with `+`, `<<=` with `<<`, and so on): a
type declares `op +` **or** `op +=`, never both, and the other is derived from it. See
[Compound assignment](#compound-assignment).

---

## Increment and Decrement

| Syntax | Name | Behavior |
|---|---|---|
| `++x` | Prefix increment | Increments `x`, returns the new value |
| `x++` | Postfix increment | Returns the current value, then increments `x` |
| `--x` | Prefix decrement | Decrements `x`, returns the new value |
| `x--` | Postfix decrement | Returns the current value, then decrements `x` |

> [!WARNING]
> Expressions that modify a variable multiple times without a sequence point (e.g., `i = i++ + ++i`) are
> **undefined behavior**. This is inherited from C++ evaluation order semantics. Avoid combining multiple
> side effects on the same variable in a single expression.

---

## Ranges

| Operator | Description | Example |
|---|---|---|
| `..` | Exclusive range (end excluded) | `0..10` -> 0 through 9 |
| `..=` | Inclusive range (end included) | `0..=10` -> 0 through 10 |

Range operators produce a `Range` object that implements iteration. Any type that satisfies the `Steppable`
interface can be used with range operators:

```kairo
interface <T> Steppable {
    fn op l++ (self) -> Self        // step forward (prefix increment)
    fn op == (self, other: T) -> bool
}
```

> [!NOTE]
> Types do not need to explicitly `impl Steppable`. If a type satisfies the required method signatures, it
> is automatically compatible with range operators. See [Interfaces](/docs/language/interfaces) for details
> on structural conformance.

Ranges also work with slicing on strings and collections:

```kairo
"hello"[1..4]         // "ell"
[1, 2, 3, 4][0..2]   // [1, 2]
```

---

## Null-Safe Access

Kairo provides null-safe operators for working with nullable types (`T?`).

| Operator | Description | Example |
|---|---|---|
| `?.` | Null-safe member access | `obj?.field` |
| `?->` | Null-safe pointer deref + member access | `ptr?->field` |

If the left-hand side is null, the entire expression evaluates to null instead of crashing.

```kairo
var user: User? = find_user("alice")
var name = user?.get_name()   // string? null if user is null
```

The non-null equivalents follow the same pattern without the safety check:

| Operator | Description |
|---|---|
| `.` | Member access |
| `->` | Pointer dereference + member access |

---

## Type Inspection

| Keyword | Return type | Description |
|---|---|---|
| `sizeof T` | `usize` | Size of type `T` in bytes |
| `alignof T` | `usize` | Alignment requirement of type `T` in bytes |
| `typeof expr` | Context-dependent | Type identity see below |

`typeof` has dual behavior depending on context:

```kairo
var x = 42
var y: typeof x = 100     // type position compiler substitutes i32

var info = typeof x        // expression position returns a TypeInfo struct
info.get_pretty_name()     // "i32"
info.get_size()            // 4
```

See [Type System](/docs/language/type-system) for full `TypeInfo` details.

---

## Type Casting `as`

`as` performs explicit type conversion. No implicit narrowing conversions exist in Kairo all narrowing casts
must use `as`. Implicit widening (e.g., `i32` to `i64`) is permitted without `as`.

```kairo
var x: i64 = 1000
var y: i8 = x as i8     // explicit narrowing may truncate

var f: f64 = 3.14
var i: i32 = f as i32   // 3 truncates toward zero
```

`as` is overloadable for user-defined types:

```kairo
class Vector2D {
    var x: f32
    var y: f32

    fn op as (self) -> string {
        return f"Vector2D({self.x}, {self.y})"
    }
}

var v = Vector2D { x: 1.0, y: 2.0 }
var s = v as string   // "Vector2D(1.0, 2.0)"
```

See [Casting](/docs/language/casting) for the full conversion rules.

---

## Operator Overloading

Operators are overloaded by defining `fn op` methods on a class or [struct](/docs/language/structures), or
in an [extension](/docs/language/extends). The syntax mirrors the operator being defined. An extension may
declare any overloadable operator except `as`, `[]`, `->`, `.*`, `->*` and `delete`, which are
**member-only**: they must be declared in the type's own body.

#### All Overload-able Operators for User-Defined Types

| Operator | Overload-able | Const-overloadable | Notes |
|---|---|---|---|
| `+` `-` `*` `/` `%` | ok | no | Returns a new value. |
| Unary `+` `-` | ok | no | Returns a new value. |
| `^^` | ok | no | Returns a new value. |
| `<<` `>>` | ok | no | Returns a new value. |
| `&` `\|` `^` `~` (bitwise) | ok | no | Returns a new value. |
| `==` | ok | no | Returns `bool`. |
| `!=` | ok | no | Returns `bool`. Derived from `op ==` when not declared. |
| `<` `<=` `>` `>=` | ok | no | Return `bool`. Derived from `op <=>` when not declared. |
| `<=>` | ok | no | Returns `Ordering`. |
| `l++` `r++` `l--` `r--` | ok | no | Mutating operators. |
| `[]` | ok | ok | Returns a place into `self` (`*T` / `*const T`). Member-only. |
| `->` | ok | ok | Returns a place into `self` (`*T` / `*const T`). Member-only. |
| `in` (containment) | ok | no | Returns `bool`. |
| `in` (iteration) | ok | no | Returns `yield T`. |
| `as` | ok | no | Returns a converted value. Member-only. |
| `delete` | ok | no | Custom destructor. Member-only. |
| `await` | ok | no | Returns the awaited value. |
| `+=` `-=` `*=` `/=` `%=` `&=` `\|=` `^=` `<<=` `>>=` | ok | no | Returns nothing. Declare either this or its binary operator, not both. |
| `=` | no | no | Generated by the compiler; cannot be overloaded. |
| `===` | no | no | Built in; needs a nullable operand. |
| `.` `::` | no | no | Language syntax; not overloadable. |
| Unary `&` `*` | no | no | Built-in pointer operations. |
| `&&` `\|\|` `!` | no | no | Preserve built-in short-circuit semantics. |
| `?.` `?->` | no | no | Derived automatically from the corresponding non-null-safe operator. |
| `..` `..=` | no | no | Implemented through the `Steppable` interface. |
| `sizeof` `alignof` `typeof` | no | no | Compile-time language keywords. |

### Standard binary and unary operators

```kairo
class Vec3 {
    var x: f32
    var y: f32
    var z: f32

    fn op + (self, other: Vec3) -> Vec3 {
        return Vec3 { x: self.x + other.x, y: self.y + other.y, z: self.z + other.z }
    }

    fn op - (self) -> Vec3 {   // unary negation
        return Vec3 { x: -self.x, y: -self.y, z: -self.z }
    }

    fn op == (self, other: Vec3) -> bool {
        return self.x == other.x && self.y == other.y && self.z == other.z
    }
}
```

Operators have no default arguments, and every comparison operator (`==`, `!=`, `<`, `<=`, `>`, `>=`)
must return `bool`.

### Derived comparisons

A comparison the type does not declare is derived: `!=` from `op ==`, and `<`, `<=`, `>`, `>=` from
`op <=>`. A declared operator always wins over a derived one, so a type can declare `op <=>` for ordering
and still declare its own `op <` when it has a faster path.

```kairo
struct Version {
    var major: i32
    var minor: i32

    fn op == (self, o: Version) -> bool { return self.major == o.major && self.minor == o.minor }
    fn op <=> (self, o: Version) -> Ordering { /* ... */ }
}

var a = Version { major: 1, minor: 2 }
var b = Version { major: 1, minor: 3 }
a != b   // derived from op ==
a < b    // derived from op <=>
```

### Compound assignment

Each compound assignment and its binary operator form a pair: `+=` / `+`, `-=` / `-`, `*=` / `*`, `/=` / `/`,
`%=` / `%`, `&=` / `&`, `|=` / `|`, `^=` / `^`, `<<=` / `<<`, `>>=` / `>>`. A type declares **one** half of a
pair and the other is derived from it. Declaring both halves is an error.

- From `op +`: `a += b` is `a = a + b`, with `a` evaluated once.
- From `op +=`: `a + b` copies `a`, applies `+=` to the copy with `b`, and yields the copy.

A compound assignment operator mutates `self` and returns nothing, so `a += b` on a struct or class is a
statement, not a value:

```kairo
struct Acc {
    var total: i32
    fn op += (self, n: i32) { self.total = self.total + n }
}

var acc = Acc { total: 0 }
acc += 5             // calls op +=
var acc2 = acc + 7   // op + derived from op +=: acc2.total == 12
```

Declaring `op +` instead derives `+=` the other way. Declare whichever form is natural for the type; the
in-place form usually avoids a copy.

Imported C++ types are not paired: they get exactly the operators their C++ declaration has.

### Increment and decrement

Use the `l` (left/prefix) or `r` (right/postfix) modifier to specify which variant you are overloading. A
type may declare both. An unmarked `op ++` or `op --` is taken as the prefix form, with a warning.

```kairo
fn op r-- (self) -> T    // postfix: x--
fn op l-- (self) -> T    // prefix:  --x
fn op l++ (self) -> T    // prefix:  ++x the ++ is on the left of the operand
fn op r++ (self) -> T    // postfix: x++ the ++ is on the right of the operand
```

# Const Overloading Operators

`op []`, `op .*`, `op ->*` and `op ->` may overload on receiver const-ness, the one exception to the const-overload restriction that applies to named methods. For a place overload, the `const self` version returns `*const T` where the `self` version returns `*T` (see [Places and values](#places-and-values------)). This exception exists because operators cannot be renamed. See [Functions](/docs/language/functions#const-overloading-restriction) for details.

```kairo
class Buffer {
    priv var data: [u8]

    fn op [] (self, index: usize) -> *u8 {
        return &self.data[index]
    }

    fn op [] (const self, index: usize) -> *const u8 {
        return &self.data[index]
    }
}

var buff = Buffer { data: [1, 2, 3] }
var p: u8 = buff[1] // `buff` is not const: the `self` overload is picked, and the read
                    // dereferences the returned `*u8` to `u8`
buff[1] = 42        // `self` overload; writes through the returned `*u8`

const cbuff = Buffer { data: [1, 2, 3] }
var c: u8 = cbuff[1] // `cbuff` is const: the `const self` overload is picked
cbuff[1] = 42        // error: the place is `*const u8`
```

A non-const receiver prefers the `self` overload; a const receiver can only use the `const self` one. The
result of a place operator is used as the value it points to, as a read or as the target of an assignment.
A named method returning `*T` is not dereferenced this way.

Every other operator follows the named-method rule: a `const self` overload of it is a redeclaration error,
the same as for a named method.

```kairo
struct V {
    var x: i32
    fn op + (self, o: V) -> V { /* ... */ }
    fn op + (const self, o: V) -> V { /* ... */ }   // error: only [], .*, ->* and -> overload on const-ness
}
```

### Special operators

| Operator | Signature | Description |
|---|---|---|
| `as` | `fn op as (self) -> TargetType` | Type conversion takes no parameters |
| `in` (containment) | `fn op in (self, other: T) -> bool` | `if item in collection` checks membership |
| `in` (iteration) | `fn op in (self) -> yield T` | `for x in collection` yields elements |
| `delete` | `fn op delete (self)` | Custom destructor called when the value goes out of scope |

The two `in` signatures are distinguished by context: the compiler uses the `-> bool` variant in `if`
expressions and the `-> yield T` variant in `for` loops.

```kairo
class IntSet {
    priv var data: [i32]

    fn op in (self, value: i32) -> bool {
        // containment check: "if 5 in my_set"
        for item in self.data {
            if item == value { return true }
        }
        return false
    }

    fn op in (self) -> yield i32 {
        // iteration: "for x in my_set"
        for item in self.data {
            yield item
        }
    }
}

var s = IntSet { data: [1, 2, 3] }

if 2 in s { /* ... */ }      // calls the bool variant

for x in s {                 // calls the yield variant
    std::println(f"{x}")
}
```

### Places and values: `[]`, `.*`, `->*`, `->`

`op []`, `op .*` and `op ->*` are either **place** or **value** operators. The declared return type
decides which.

A safe pointer return (`*T` or `*const T`) makes it a place:

- `a[i]` is the `T` the pointer points at. It is an lvalue, and `const` if the pointer was.
- `a[i] = x` and `a[i] += 1` write into `self`, and `&a[i]` gives the pointer back.
- C++ sees the operator as returning `T&` / `const T&`.

Any other return makes it a value operator: `a[i]` is the returned value, an rvalue. You can read it but
not assign to it, and `&a[i]` is an error.

`unsafe *T` is rejected as a return type, because it is neither a place nor a value. A pointer return from
`[]`, `.*` or `->*` always means a place, so these operators cannot return a pointer by value. Use a named
method to hand out a pointer.

`op ->` isn't part of this rule. It must return `*T` or `*const T`, and `->` is then applied to that
result, as with C++'s `operator->`. `unsafe *T` is rejected there too.

Both kinds can be overloaded on a `const self` receiver.

```kairo
struct <T> Buf {
    var data: [T; 4]
    fn op [](self, i: usize) -> *T { return &self.data[i] }                  // place
    fn op [](const self, i: usize) -> *const T { return &self.data[i] }      // place, const receiver
    fn op [](self, r: Range<usize>) -> [T;] { ... }                          // value: a slice
}

var b = Buf<i32>{ data: [1, 2, 3, 4] }
b[0] = 10          // through the place
var s = b[0..2]    // a new value
var p = &b[1]      // *i32 into b.data
```

### Delete Operator

`op delete` defines custom destruction logic. If not defined, the compiler generates a default destructor. If any member has a deleted destructor (`fn op delete() = delete`), the containing type's destructor is also deleted and instances must be managed in an [unsafe](/docs/language/unsafe) context.

> [!NOTE]
> The `op delete` operator is **not** the same as C++'s `delete` operator. Kairo's `op delete` is simply a cleanup hook that can either be explicitly called or automatically invoked when a value goes out of scope. It is not used to free memory allocated with `@create T()`.

```kairo
class FileHandle {
    priv var fd: i32

    fn op delete (self) {
        close(self.fd)
    }
}
```

See [Tether](/docs/language/tether) for details on destruction order and allocator interaction.


---

## Statement Expressions

A statement expression runs a block of statements and yields the value of its last expression:

```kairo
fn main() -> i32 {
    var x = 1
    var y = ({
        var t = x * 10
        t + 2
    })
    return x + y   // 13
}
```

The form is `({ statements... expression })`. Its value and type are those of the last expression.

- The last statement must be an expression. A block that ends in `var`, an `if` statement or `return`, or
  an empty block, is an error.
- Locals declared inside are scoped to the block and destroyed at its closing brace.
- `return`, `break` and `continue` inside the block jump out of it as they would anywhere else; `return`
  returns from the enclosing function.
- The expected type reaches the last expression: in `var b: u8 = ({ 5 })` the literal is a `u8`.
- The value is a copy. A statement expression cannot yield a fixed-size array, since arrays are not copied
  implicitly.
- Inside the block, a newline ends a statement as it does in any block.

`({` always opens a statement expression. A set or map literal, or an anonymous initializer, is written
without surrounding parentheses.

This is the only place a block yields a value. The arms of an `if` or `match` expression are single
expressions, and no other block returns its last expression implicitly.

---

## Precedence

Operators are listed from highest precedence (tightest binding) to lowest. Operators on the same row have
equal precedence and associate in the direction shown.

| Precedence | Operators | Associativity | Description |
|---|---|---|---|
| 1 | Literals, names, `( )` grouping, `({ ... })` | | Primary expressions |
| 2 | `::` | Left | Scope resolution |
| 3 | `()` `[]` `.` `->` `?.` `?->` | Left | Postfix / member access |
| 4 | `++` `--` (postfix) | Left | Postfix increment/decrement |
| 5 | `++` `--` (prefix) `!` `~` `+` `-` (unary) `*` `&` `sizeof` `alignof` `typeof` | Right | Prefix / unary |
| 6 | `as` | Left | Type cast |
| 7 | `^^` | Right | Exponentiation |
| 8 | `*` `/` `%` | Left | Multiplicative |
| 9 | `+` `-` | Left | Additive |
| 10 | `<<` `>>` | Left | Bitwise shift |
| 11 | `<` `<=` `>` `>=` `<=>` `in` | Left | Relational / three-way / containment |
| 12 | `==` `!=` `===` | Left | Equality |
| 13 | `&` | Left | Bitwise AND |
| 14 | `^` | Left | Bitwise XOR |
| 15 | `\|` | Left | Bitwise OR |
| 16 | `&&` | Left | Logical AND |
| 17 | `\|\|` | Left | Logical OR |
| 18 | `..` `..=` | None | Range |
| 19 | `??` | Right | Null coalescing |
| 20 | `=` `+=` `-=` `*=` `/=` `%=` `&=` `\|=` `^=` `<<=` `>>=` | Right | Assignment |

`as` binds looser than every prefix operator and tighter than every binary one: `-1 as u8` casts `-1`,
`&x as *const T` casts the address, and `x as i64 + 1` is `(x as i64) + 1`.

> [!NOTE]
> `==` binds tighter than `&&` and `||` compound conditions like `a == b && c == d` do not require
> explicit parentheses. This matches C/C++ precedence.

When in doubt, use parentheses. The compiler does not warn about precedence ambiguity, but explicit grouping
improves readability.

---

## Evaluation Order

Call arguments are evaluated **left to right**, and the receiver of a method call comes first. Given
`f(a(), b())`, `a()` runs before `b()`; given `x.m(a())`, `x` is evaluated before `a()`.

```kairo
fn g(@inout n: i32) -> i32 { n += 1; return n * 10 }

var n = 0
f(g(&n), g(&n))     // always f(10, 20)
```

Named arguments follow the same rule: they run in the order written, not parameter order. Defaults for
omitted arguments run after all explicit arguments, in parameter order. See
[Functions](/docs/language/functions#evaluation-order).

`&&` and `||` are also left to right, with short-circuiting. See
[Control Flow](/docs/language/control-flow).

The operands of a primitive operator follow C++ and their order is unspecified: in `a() + b()`, either call
may run first.

> [!WARNING]
> Do not rely on the order of operands with side effects. Split the side effects into separate statements.

---

## Operators Not in Kairo

For C++ developers the following C++ operators have no equivalent in Kairo:

| C++ Operator | Kairo Alternative |
|---|---|
| `? :` (ternary) | `if`/`else` expressions |
| `,` (comma operator) | Not supported use separate statements |
| `new` / `delete` | `@create T()` / automatic via Tether, or `op delete` for custom destructors |
| `typeid` | `typeof expr` returns `TypeInfo` |
| `const_cast` / `reinterpret_cast` / `static_cast` / `dynamic_cast` | `as` for safe casts; see [Casting](/docs/language/casting) |

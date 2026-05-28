# Operators

Kairo's operators follow C-style precedence and semantics with a few additions: exponentiation (`^^`), deep
equality (`===`), null-safe access (`?.`, `?->`), and ranges (`..`, `..=`). All operators can be overloaded
for user-defined types.

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

`^^` works on any integer combination (`i32 ^^ i32`, `u64 ^^ u8`, etc.) and on float bases with integer
exponents (`f64 ^^ i32`). Overflow follows the same rules as other arithmetic see below.

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
| `===` | Deep equality | `a === b` |

`<=>` returns an ordering value, matching C++20 spaceship operator semantics.

### `==` vs `===`

On pointers, `==` compares **addresses** whether two pointers point to the same memory location. `===`
dereferences both pointers (with a runtime null check) and compares the **values** they point to.

```kairo
var z = 42
var x = &z
var y = &z

x == y    // true same address
x === y   // true dereferenced values are equal
```

```kairo
var a = 42
var b = 42
var p = &a
var q = &b

p == q    // false different addresses
p === q   // true both point to 42
```

For user-defined types, `===` can be overloaded to implement deep equality. By default it is only defined for
pointer types.

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

All compound assignment operators desugar to `x = x op y`.

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
    fn op l++ (self) -> Steppable   // step forward (prefix increment)
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
| `?.*` | Null-safe deref member pointer | `obj?.*member_ptr` |
| `?->*` | Null-safe pointer deref + member pointer deref | `ptr?->*member_ptr` |

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
| `.*` | Dereference member pointer |
| `->*` | Pointer dereference + member pointer dereference |

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

Operators are overloaded by defining `fn op` methods on a class, [struct](/docs/language/structures) OR (via [extends](/docs/language/extends)). The syntax mirrors the operator being defined.

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

### Increment and decrement

Use the `l` (left/prefix) or `r` (right/postfix) modifier to specify which variant you are overloading. The
compiler warns if the modifier is omitted.

```kairo
fn op r-- (self) -> T    // postfix: x--
fn op l-- (self) -> T    // prefix:  --x
fn op l++ (self) -> T    // prefix:  ++x the ++ is on the left of the operand
fn op r++ (self) -> T    // postfix: x++ the ++ is on the right of the operand
```

### Special operators

| Operator | Signature | Description |
|---|---|---|
| `as` | `fn op as (self) -> TargetType` | Type conversion takes no parameters |
| `===` | `fn op === (self, other: T) -> bool` | Deep equality |
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

### `op delete`

`op delete` defines custom destruction logic. If not defined, the compiler generates a default destructor. If
any member has a deleted destructor (`fn op delete() = delete`), the containing type's destructor is also
deleted and instances must be managed in an [unsafe](/docs/language/unsafe) context.

```kairo
class FileHandle {
    priv var fd: i32

    fn op delete (self) {
        close(self.fd)
    }
}
```

See [AMT](/docs/language/amt) for details on destruction order and allocator interaction.

> [!CAUTION]
> Overloading operators in an `unsafe` context is not permitted. All operator overloads must be safe.

---

## Precedence

Operators are listed from highest precedence (tightest binding) to lowest. Operators on the same row have
equal precedence and associate in the direction shown.

| Precedence | Operators | Associativity | Description |
|---|---|---|---|
| 1 | `::` | Left | Scope resolution |
| 2 | `()` `[]` `.` `->` `.*` `->*` `?.` `?->` `?.*` `?->*` | Left | Postfix / member access |
| 3 | `++` `--` (postfix) | Left | Postfix increment/decrement |
| 4 | `++` `--` (prefix) `!` `~` `+` `-` (unary) `*` `&` `sizeof` `alignof` `typeof` | Right | Prefix / unary |
| 5 | `^^` | Right | Exponentiation |
| 6 | `*` `/` `%` | Left | Multiplicative |
| 7 | `+` `-` | Left | Additive |
| 8 | `<<` `>>` | Left | Bitwise shift |
| 9 | `<=>` | Left | Three-way comparison |
| 10 | `<` `<=` `>` `>=` | Left | Relational |
| 11 | `==` `!=` `===` | Left | Equality |
| 12 | `&` | Left | Bitwise AND |
| 13 | `^` | Left | Bitwise XOR |
| 14 | `\|` | Left | Bitwise OR |
| 15 | `&&` | Left | Logical AND |
| 16 | `\|\|` | Left | Logical OR |
| 17 | `..` `..=` | Left | Range |
| 18 | `=` `+=` `-=` `*=` `/=` `%=` `&=` `\|=` `^=` `<<=` `>>=` | Right | Assignment |
| 19 | `in` | Left | Containment / iteration |
| 20 | `as` | Left | Type cast |

> [!NOTE]
> `==` binds tighter than `&&` and `||` compound conditions like `a == b && c == d` do not require
> explicit parentheses. This matches C/C++ precedence.

When in doubt, use parentheses. The compiler does not warn about precedence ambiguity, but explicit grouping
improves readability.

---

## Evaluation Order

Evaluation order of subexpressions is **undefined** in Kairo. Given `f(a(), b())`, there is no guarantee
that `a()` executes before `b()`. This is inherited from C++ semantics.

> [!WARNING]
> Do not rely on evaluation order for correctness. Expressions with multiple side effects on the same variable
> in a single statement are undefined behavior.

---

## Operators Not in Kairo

For C++ developers the following C++ operators have no equivalent in Kairo:

| C++ Operator | Kairo Alternative |
|---|---|
| `? :` (ternary) | `if`/`else` expressions |
| `,` (comma operator) | Not supported use separate statements |
| `new` / `delete` | `std::create<T>` / automatic via AMT, or `op delete` for custom destructors |
| `typeid` | `typeof expr` returns `TypeInfo` |
| `const_cast` / `reinterpret_cast` / `static_cast` / `dynamic_cast` | `as` for safe casts; see [Casting](/docs/language/casting) |
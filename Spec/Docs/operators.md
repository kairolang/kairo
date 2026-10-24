# Operators

Kairo's operators follow C-style precedence and semantics with a few additions: exponentiation (`^^`), null-aware equality (`===`), null-safe access (`?.`, `?->`), and ranges (`..`, `..=`). Most operators can be overloaded for user-defined types; the [overload table](/docs/language/operator-overloading/#all-overload-able-operators-for-user-defined-types) lists which.

## In this section

- [Operator Overloading](/docs/language/operator-overloading/)

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

The base of `^^` takes the expected type, the exponent may be any integer type, and the result has the base's type (`u64 ^^ u8` is `u64`, `f64 ^^ i32` is `f64`). A float exponent is an error.

- `x ^^ 0` is `1`.
- A negative exponent is `(1 / x) ^^ n` using the base type's own division. For an integer base that is `0`, `1` or `-1`; for a float base it is the reciprocal.
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

See [Primitives](/docs/language/primitives/#overflow-behavior) for full details on numeric type behavior.

### Floating-point overflow

Overflow produces `inf`, underflow produces `0.0`. Operations that produce `NaN` (e.g., `0.0 / 0.0`, `sqrt(-1.0)`) propagate `NaN` per IEEE 754 no crash, no trap. Check explicitly with `std::is_nan()`.

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

`===` is valid when at least one operand is [nullable](/docs/language/nullables/) (`T?`). `a === b` is true when both are non-null and equal. On nullable pointers (`*T?`) it compares the values they point to, where `==` compares **addresses**. Using `===` where neither operand is nullable is an error, including two `*T`. To compare the pointees of two non-null pointers, dereference them and use `==`.

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

Short-circuit evaluation applies: `&&` does not evaluate the right operand if the left is `false`, and `||` does not evaluate the right operand if the left is `true`. This is identical to C++.

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

On primitives, `x op= y` behaves like `x = x op y` with `x` evaluated once. For user-defined types, a compound assignment and its binary operator form one pair (`+=` with `+`, `<<=` with `<<`, and so on): a type declares `op +` **or** `op +=`, never both, and the other is derived from it. See [Compound assignment](/docs/language/operator-overloading/#compound-assignment).

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
> **undefined behavior**. This is inherited from C++ evaluation order semantics. Avoid combining multiple side effects on the same variable in a single expression.

---

## Ranges

| Operator | Description | Example |
|---|---|---|
| `..` | Exclusive range (end excluded) | `0..10` -> 0 through 9 |
| `..=` | Inclusive range (end included) | `0..=10` -> 0 through 10 |

Range operators produce a `Range` object that implements iteration. Any type that satisfies the `Steppable` interface can be used with range operators:

```kairo
interface <T> Steppable {
    fn op l++ (self) -> Self        // step forward (prefix increment)
    fn op == (self, other: T) -> bool
}
```

> [!NOTE]
> Types do not need to explicitly `impl Steppable`. If a type satisfies the required method signatures, it is automatically compatible with range operators. See [Interfaces](/docs/language/interfaces/) for details on structural conformance.

Ranges also work with slicing on strings and collections:

```kairo
"hello"[1..4]         // "ell"
[1, 2, 3, 4][0..2]   // [1, 2]
```

---

## Null-Safe Access

Kairo provides null-safe operators for working with [nullable types](/docs/language/nullables/) (`T?`).

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

See [Type System](/docs/language/type-system/) for full `TypeInfo` details.

---

## Type Casting `as`

`as` performs explicit type conversion. No implicit narrowing conversions exist in Kairo all narrowing casts must use `as`. [Implicit widening](/docs/language/casting-implicit/#widening) (e.g., `i32` to `i64`) is permitted without `as`.

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

See [Casting](/docs/language/casting/) for the full conversion rules.

---

## Operator Overloading

Operator overloading is covered in [Operator Overloading](/docs/language/operator-overloading/).

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

- The last statement must be an expression. A block that ends in `var`, an `if` statement or `return`, or an empty block, is an error.
- Locals declared inside are scoped to the block and destroyed at its closing brace.
- `return`, `break` and `continue` inside the block jump out of it as they would anywhere else; `return` returns from the enclosing function.
- The expected type reaches the last expression: in `var b: u8 = ({ 5 })` the literal is a `u8`.
- The value is a copy. A statement expression cannot yield a fixed-size array, since arrays are not copied implicitly.
- Inside the block, a newline ends a statement as it does in any block.

`({` always opens a statement expression. A set or map literal, or an anonymous initializer, is written without surrounding parentheses.

This is the only place a block yields a value. The arms of an `if`, `match`, or `try` expression are single `=> expr` values, and no other block returns its last expression implicitly. A statement expression is how an arm holds several statements: `if ready => ({ var t = load(); (t.value); }) else => 0`.

---

## Precedence

Operators are listed from highest precedence (tightest binding) to lowest. Operators on the same row have equal precedence and associate in the direction shown.

| Precedence | Operators | Associativity | Description |
|---|---|---|---|
| 1 | Literals, names, `( )` grouping, `({ ... })`, `match` | | Primary expressions |
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
| 21 | `if` / `try` expressions | | Value-form `if` and `try` |

`if` and `try` expressions bind looser than every operator. Their last arm extends as far right as it can, so `x + if c => 1 else => 2 + 5` is `x + (if c => 1 else => (2 + 5))`. An `if` or `try` used as an operand produces a warning ([S078W](/docs/language/diagnostics/#s078w-if-or-try-expression-as-an-operators-operand)); parenthesize it: `x + (if c => 1 else => 2) + 5`.

A [`match` expression](/docs/language/pattern-matching/#match-as-an-expression) closes with `}` and binds as a primary expression: `match k { ... } + 1` needs no parentheses.

`=>` is punctuation, not an operator: it has no precedence and cannot be overloaded. It introduces the value of an arm in the value forms of `if`, `match`, and `try`. See [Control Flow](/docs/language/control-flow/#if-as-an-expression-ternary-equivalent).

`as` binds looser than every prefix operator and tighter than every binary one: `-1 as u8` casts `-1`, `&x as *const T` casts the address, and `x as i64 + 1` is `(x as i64) + 1`.

> [!NOTE]
> `==` binds tighter than `&&` and `||` compound conditions like `a == b && c == d` do not require explicit parentheses. This matches C/C++ precedence.

When in doubt, use parentheses. Apart from an `if` or `try` expression used as an operand, the compiler does not warn about precedence ambiguity, but explicit grouping improves readability.

---

## Evaluation Order

Call arguments are evaluated **left to right**, and the receiver of a method call comes first. Given `f(a(), b())`, `a()` runs before `b()`; given `x.m(a())`, `x` is evaluated before `a()`.

```kairo
fn g(@inout n: i32) -> i32 { n += 1; return n * 10 }

var n = 0
f(g(&n), g(&n))     // always f(10, 20)
```

Named arguments follow the same rule: they run in the order written, not parameter order. Defaults for omitted arguments run after all explicit arguments, in parameter order. See [Functions](/docs/language/functions-parameters/#evaluation-order).

`&&` and `||` are also left to right, with short-circuiting. See [Control Flow](/docs/language/control-flow/#short-circuit-evaluation).

The operands of a primitive operator follow C++ and their order is unspecified: in `a() + b()`, either call may run first.

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
| `const_cast` / `reinterpret_cast` / `static_cast` / `dynamic_cast` | `as` for safe casts; see [Casting](/docs/language/casting/) |

---

## See also

- [Operator Overloading](/docs/language/operator-overloading/)
- [Control Flow](/docs/language/control-flow/)
- [Casting](/docs/language/casting/)
- [Nullables](/docs/language/nullables/)
- [Type System](/docs/language/type-system/)
- [Primitives](/docs/language/primitives/)
- [Pattern Matching](/docs/language/pattern-matching/)
- [Interfaces](/docs/language/interfaces/)

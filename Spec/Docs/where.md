# Where Clauses

`where` attaches runtime-conditional constraints to function declarations. A `where` clause
specifies a condition that is checked at the call site if it fails, execution falls through to
the next matching overload. The compiler folds multiple `where`-constrained overloads into a
single function with branch dispatch.

For compile-time constraints, see [Requires Clauses](/docs/language/requires).

| Property | Guarantee |
|---|---|
| Evaluation time | Runtime |
| Memory safe | Yes |
| Thread safe | Yes |
| Undefined behavior | No |
| Requires unsafe | No |
| Valid on functions | Yes |
| Valid on types | No use `requires` |
| Valid on interfaces | No interfaces are zero-cost, use `requires` |

---

## Basic Syntax

A `where` clause appears after the parameter list and return type, before the function body:

```kairo
fn sqrt(x: f64) -> f64
  where x >= 0.0 {
    return std::math::sqrt(x)
}

fn sqrt(x: f64) -> f64 {
    return 0.0   // fallback for negative input
}
```

At the call site, the compiler generates a branch. If the condition holds, the constrained
overload runs. If not, execution falls to the next candidate.

Multiple conditions are combined with boolean operators:

```kairo
fn safe_divide(a: i32, b: i32) -> i32
  where b != 0 && a >= 0 {
    return a / b
}

fn safe_divide(a: i32, b: i32) -> i32 {
    return 0   // fallback
}
```

---

## Fallback Requirement

Every `where`-constrained overload must have a fallback an overload with no `where` clause (or
a `where` clause that covers the remaining cases). If no fallback exists, the compiler emits an
error:

```
error: no fallback overload for 'sqrt' when where condition fails
  --> src/math.k:1:1
  1 | fn sqrt(x: f64) -> f64
  2 |   where x >= 0.0 {
  note: add an overload without a 'where' clause to handle all remaining cases
```

The fallback is the compiler's guarantee that every call site has a valid code path.

---

## Declaration Order Determines Priority

When multiple `where`-constrained overloads exist for the same function, the compiler checks them
in declaration order. The first satisfied condition wins. The unconstrained overload is always
the final fallback:

```kairo
fn categorize(x: i32) -> string where x > 100  { return "high" }
fn categorize(x: i32) -> string where x > 0    { return "positive" }
fn categorize(x: i32) -> string                 { return "non-positive" }
```

Conceptual codegen:

```kairo
fn categorize(x: i32) -> string {
    if x > 100     { return "high" }
    else if x > 0  { return "positive" }
    else           { return "non-positive" }
}
```

Declaration order is the programmer's explicit priority control. The compiler does not attempt to
determine which condition is "more specific" it chains them sequentially in the order they
appear in source.

> [!WARNING]
> A `where` condition that is a strict subset of a preceding condition will never fire. The
> compiler emits a warning when it can statically determine that a `where` clause is unreachable:
>
> ```kairo
> fn process(x: i32) -> string where x > 50 { return "high" }
> fn process(x: i32) -> string where x > 100 { return "very high" }  // warning: unreachable
> fn process(x: i32) -> string { return "low" }
> ```

---

## Overlapping Conditions

If two `where` clauses have overlapping conditions that cannot be statically determined to be
disjoint, the compiler emits a warning:

```kairo
fn handle(x: i32) -> string where x > 0 && x < 100 { return "small positive" }
fn handle(x: i32) -> string where x > 50            { return "over 50" }  // warning: overlaps with above
fn handle(x: i32) -> string                          { return "other" }
```

Declaration order still determines the result `x == 75` hits the first overload but the
warning signals that the intent may not match the behavior.

---

## Where in Match

The `where` keyword also appears in `match` arms as a guard condition. Match guards are always
evaluated at runtime and are independent of the overload dispatch system they are simple boolean
filters on a matched pattern, not function overloads:

```kairo
match result {
    case .Found(var key, var value) where value > 0 {
        process(key, value)
    }
    case .Found(var key, var value) {
        skip(key)
    }
    default { }
}
```

A match guard that fails causes the arm to be skipped and evaluation continues to the next arm.
See [Control Flow](/docs/language/control-flow#match) for the full `match` syntax.

---

## Runtime Dispatch and Timing

`where` dispatch introduces a branch at the call site. In most cases this is a single conditional
jump that the branch predictor handles efficiently. However, if the constrained function processes
sensitive data, the branch structure can leak information through execution time differences.

> [!CAUTION]
> Runtime `where` dispatch creates observable branching. If the function handles sensitive data
> (cryptographic keys, authentication tokens, private user data), the timing difference between
> the constrained and fallback paths may be measurable by an attacker. Use constant-time
> implementations in those cases and do not rely on `where` dispatch for security-critical
> branching.

---

## Where and panic

`where` clauses and `panic` are orthogonal. `where` selects which overload runs based on a
runtime condition. `panic` signals an error from within a function body. They can coexist:

```kairo
fn connect(host: string, port: i32) panic -> Connection
  where port > 0 && port <= 65535 {
    var conn = tcp_connect(host, port)
    if !conn.is_valid() {
        panic std::Error::IO("connection failed")
    }
    return conn
}

fn connect(host: string, port: i32) -> Connection {
    // fallback: invalid port, return a no-op connection
    return Connection::invalid()
}
```

---

## Where and unsafe

`where` constraints and `unsafe` overloads are in separate namespaces. Safe overloads dispatch
among themselves based on `where` conditions. Unsafe overloads are selected explicitly by the
caller with the `unsafe` keyword and do not participate in `where`-based dispatch:

```kairo
// Safe dispatch: where selects between these
fn access(data: [i32], index: i32) -> i32
  where index >= 0 && index < data.length() {
    return data[index]
}

fn access(data: [i32], index: i32) -> i32 {
    return 0   // fallback
}

// Unsafe overload: separate namespace, caller selects explicitly
fn access(data: [i32], index: i32) unsafe -> i32 {
    return data[index]   // no bounds check
}

var a = access(data, 5)          // safe dispatch
var b = unsafe access(data, 5)   // unsafe overload, no where dispatch
```

See [Unsafe](/docs/language/unsafe) for the unsafe overload model.

---

## What where Cannot Do

`where` is only valid on free functions and methods. The following are compile errors:

```kairo
// compile error: where on a type use requires instead
class <T> Buffer
  where sizeof T <= 128 {
    var data: [T; 16]
}

// compile error: where on an interface method interfaces are zero-cost, use requires
interface Validator {
    fn validate(self, input: string) -> bool
      where input.length() > 0
}
```

Type instantiation is always compile-time. Interface conformance is a zero-cost structural
contract. Neither admits runtime dispatch. Use `requires` for both.

---

## Summary

```kairo
// Basic runtime dispatch with fallback
fn sqrt(x: f64) -> f64 where x >= 0.0 { return std::math::sqrt(x) }
fn sqrt(x: f64) -> f64                 { return 0.0 }

// Multiple constrained overloads declaration order is priority
fn classify(temp: f64) -> string where temp > 100.0 { return "boiling" }
fn classify(temp: f64) -> string where temp > 0.0   { return "liquid" }
fn classify(temp: f64) -> string                     { return "frozen" }

// Where with panic
fn parse_positive(input: string) panic -> i32
  where input.length() > 0 {
    var n = std::parse<i32>(input)
    if n <= 0 { panic std::Error::Runtime("not positive") }
    return n
}

fn parse_positive(input: string) -> i32 {
    return 0
}

// Where coexisting with unsafe overload
fn divide(a: i32, b: i32) -> i32 where b != 0 { return a / b }
fn divide(a: i32, b: i32) -> i32               { return 0 }
fn divide(a: i32, b: i32) unsafe -> i32        { return a / b }  // no check

var result = divide(10, 0)          // 0 (fallback)
var fast   = unsafe divide(10, 2)   // 5 (unsafe, no dispatch)
```
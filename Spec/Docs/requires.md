# Requires Clauses

`requires` attaches compile-time constraints to declarations. A `requires` clause specifies a
condition that must hold at compile time if it doesn't, the program does not compile. There is
no runtime fallback, no dispatch, no branching. `requires` is a static gate.

For runtime-conditional dispatch, see [Where Clauses](/docs/language/where).

| Property | Guarantee |
|---|---|
| Evaluation time | Compile time, always |
| Memory safe | Yes |
| Runtime cost | Zero |
| Valid on functions | Yes |
| Valid on types | Yes |
| Valid on interface methods | Yes |
| Valid on interfaces | Yes (constrains conforming types) |

---

## Basic Syntax

A `requires` clause appears after the parameter list and return type, before the function body:

```kairo
fn divide(a: i32, b: i32) -> i32
  requires b != 0 {
    return a / b
}
```

If the condition cannot be evaluated at compile time, the compiler emits a hard error:

```
error: requires expression is not compile-time evaluable
  --> src/math.k:1:32
  1 | fn divide(a: i32, b: i32) -> i32
  2 |   requires b != 0 {
    |            ^^^^^^ depends on runtime value 'b'
  note: for runtime-conditional dispatch, use 'where'
```

Multiple conditions are combined with boolean operators in a single expression:

```kairo
fn safe_index(arr: [i32], i: i32) -> i32
  requires i >= 0 && i < arr.length() {
    return arr[i]
}
```

---

## Compile-Time Expressions

Any expression the compiler can evaluate statically is valid in a `requires` clause:

| Expression | Example |
|---|---|
| `sizeof T)` | `requires sizeof(T <= 64` |
| `alignof T)` | `requires alignof(T >= 16` |
| Arithmetic and comparisons | `requires N > 0 && N <= 1024` |
| `eval` variables and functions | `requires is_power_of_two(N)` |
| Type trait checks | `requires T impl Comparable` |
| `typeof` queries | `requires typeof T == i32` |

If the expression depends on a runtime value, it belongs in a `where` clause, not `requires`.

---

## Type Constraints

`impl` and `derives` bounds can appear in `requires` clauses as an alternative to inline bounds
on type parameters. The compiler desugars them identically:

```kairo
// These are equivalent:
fn <T impl Serializable> save(data: T) { ... }
fn <T> save(data: T) requires T impl Serializable { ... }
```

The `requires` form is preferred when constraints are long or involve relationships between
multiple type parameters:

```kairo
fn <T, U> convert(input: T) -> U
  requires T impl Serializable && U impl Deserializable {
    var bytes = input.serialize()
    return U::from_bytes(bytes)
}
```

---

## Requires on Types

`requires` on a class, struct, or enum is checked at instantiation time. A violation is a hard
compile error at the point of use:

```kairo
class <T> SmallBuffer
  requires sizeof T <= 128 {
    var data: [T; 16]
}

SmallBuffer<i32>()         // ok: sizeof i32 == 4
SmallBuffer<[u8; 256]>()   // compile error: sizeof [u8; 256] == 256, exceeds 128

struct <T> Aligned16
  requires alignof T >= 16 {
    var value: T
}

enum <T> Compact
  requires sizeof T <= 8 {
    Some { value: T },
    None,
}
```

Type-level constraints are always `requires`. There is no runtime dispatch on type instantiation
either the type is valid or it isn't.

---

## Requires on Interface Methods

`requires` on an interface method constrains what conforming types must satisfy. The conforming
type must implement the method with an identical `requires` clause:

```kairo
interface Accumulator {
    fn add(self, value: i32) -> Self
      requires value > 0
}

class Counter impl Accumulator {
    var total: i32

    fn Counter(self) { self.total = 0 }

    fn add(self, value: i32) -> Self
      requires value > 0 {
        self.total += value
        return self
    }
}
```

Because interfaces are zero-cost structural contracts, `requires` is the only valid constraint
keyword on interface members. `where` is not permitted runtime dispatch inside an interface
method would violate the zero-cost guarantee.

---

## Requires on Interfaces

A `requires` clause on an interface declaration constrains which types can conform. A type that
does not satisfy the `requires` cannot implement the interface, even if it has all the required
methods:

```kairo
interface <T> SmallStorable
  requires sizeof T <= 64 {
    fn store(self) -> [byte]
    fn load(data: [byte]) -> T
}
```

This is distinct from `requires` on an individual method it applies to the entire interface
as a precondition on conformance.

---

## Requires and eval

`requires` expressions are evaluated by the same compile-time engine as `eval`. Any `eval`
function or variable is usable in a `requires` clause:

```kairo
eval fn is_power_of_two(n: i32) -> bool {
    return n > 0 && (n & (n - 1)) == 0
}

fn <const N: i32> clear_aligned(@inout buf: [u8; N])
  requires is_power_of_two(N) {
    for i in 0..N { buf[i] = 0 }
}

var a: [u8; 256]
var b: [u8; 300]
clear_aligned<256>(&a)  // ok: 256 is a power of two
clear_aligned<300>(&b)  // compile error: 300 is not a power of two
```

See [Eval](/docs/language/eval) for compile-time evaluation rules.

---

## Requires and panic

`requires` and `panic` serve different purposes and can coexist. `requires` filters invalid inputs
before the function body executes. `panic` handles valid inputs that produce errors during
processing:

```kairo
fn parse_port(input: string) panic -> i32
  requires input.length() > 0 {
    var port = std::parse<i32>(input)
    if port < 0 || port > 65535 {
        panic std::Error::Runtime("port out of range")
    }
    return port
}
```

The `requires` clause rejects empty strings at compile time (when the argument is a constant) or
documents the precondition for the caller. The `panic` handles the runtime error case of a
non-empty string that isn't a valid port.

---

## Summary

```kairo
// Compile-time size constraint on a generic
fn <T> stack_alloc() -> T
  requires sizeof T <= 4096 {
    // ...
}

// Type constraint in requires clause
fn <T, U> transform(input: T) -> U
  requires T impl Readable && U impl Writable {
    // ...
}

// Requires on a class
class <T> InlineBuffer
  requires sizeof T <= 64 {
    var data: [T; 8]
}

// Requires on an interface method
interface Validator {
    fn validate(self, input: string) -> bool
      requires input.length() > 0
}

// Requires with eval function
eval fn fits_in_cache_line(n: i32) -> bool = n <= 64

struct <T> CacheAligned
  requires fits_in_cache_line(sizeof T) {
    var value: T
}
```

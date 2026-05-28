# Where Clauses

Where clauses attach constraints to declarations. A `where` clause specifies a condition that must hold
for the declaration to be valid. If the condition can be evaluated at compile time, a violation is a
compile error. If it can only be evaluated at runtime, the compiler generates dispatch code that selects
among overloads based on which constraints are satisfied.

| Property | Guarantee |
|---|---|
| Compile-time check | When the expression is compile-time evaluable |
| Runtime check | When the expression depends on runtime values |
| Memory safe | Yes |
| Thread safe | Yes |
| Undefined behavior | No |
| Requires unsafe | No |

---

## Basic Syntax

A `where` clause appears after the parameter list (and return type, if present) and before the function
body. It takes a single boolean expression:

```kairo
fn divide(a: i32, b: i32) -> i32
  where b != 0 {
    return a / b
}
```

Multiple conditions are combined with boolean operators in a single expression:

```kairo
fn safe_index(arr: [i32], i: i32) -> i32
  where i >= 0 && i < arr.len() {
    return arr[i]
}
```

---

## Compile-Time Constraints

When the `where` expression can be evaluated at compile time, the compiler checks it statically. A
violation is a hard compile error:

```kairo
fn <T> fixed_buffer(size: i32) -> [T; size]
  where sizeof(T) <= 64 && size > 0 {
    // ...
}

fixed_buffer<u8>(100)     // ok: sizeof(u8) == 1, 100 > 0
fixed_buffer<u8>(-1)      // compile error: -1 > 0 is false
```

Compile-time constraints are useful for restricting generic instantiations, enforcing size limits, and
catching invalid configurations before codegen.

### Available compile-time expressions

Any expression that the compiler can evaluate statically is valid, including:

- `sizeof(T)` size of a type in bytes
- `alignof(T)` alignment of a type in bytes
- Literal comparisons and arithmetic
- `eval` variables and functions (see [Eval](/docs/language/eval))
- Type trait checks (`T impl SomeInterface`, `T derives SomeClass`)

---

## Type Constraints in Where Clauses

`impl` and `derives` bounds can appear in `where` clauses as an alternative to inline bounds on type
parameters. The compiler desugars them into the equivalent generic bound:

```kairo
// These are equivalent:
fn <T impl Serializable> save(data: T) { ... }
fn <T> save(data: T) where T impl Serializable { ... }

// Useful when the constraint is complex or involves multiple parameters:
fn <T, U> convert(input: T) -> U
  where T impl Serializable && U impl Deserializable {
    var bytes = input.serialize()
    return U::from_bytes(bytes)
}
```

The `where` form is preferred when constraints are long or involve relationships between multiple type
parameters, keeping the generic parameter list clean.

---

## Runtime Constraints and Overload Dispatch

When a `where` expression depends on runtime values, the compiler cannot check it statically. Instead,
it generates dispatch code that selects among candidate overloads at runtime. The caller must provide
a fallback overload without a `where` clause (or with a different `where` clause) that covers the
failing case:

```kairo
fn divide(a: i32, b: i32) -> i32
  where b != 0 {
    return a / b
}

fn divide(a: i32, b: i32) -> i32 {
    return 0   // fallback when b == 0
}
```

The compiler folds these into a single function with branch dispatch:

```kairo
// Conceptual codegen:
fn divide(a: i32, b: i32) -> i32 {
    if b != 0 {
        return a / b
    } else {
        return 0
    }
}
```

If no unconstrained fallback exists and the constraint is runtime-evaluated, the compiler emits an
error every runtime code path must have a candidate.

### Declaration order determines priority

When multiple `where`-constrained overloads exist for the same function, they are checked in
declaration order. The first satisfied constraint wins. The unconstrained overload is always the
final fallback:

```kairo
fn classify(x: i32) -> string where x > 100 { return "high" }
fn classify(x: i32) -> string where x > 0   { return "positive" }
fn classify(x: i32) -> string               { return "non-positive" }
```

Codegen:

```kairo
// Conceptual:
fn classify(x: i32) -> string {
    if x > 100      { return "high" }
    else if x > 0   { return "positive" }
    else            { return "non-positive" }
}
```

The user controls priority by controlling declaration order. The compiler does not attempt to
determine which constraint is "more specific" it chains them sequentially.

> [!CAUTION]
> Runtime `where` dispatch introduces branching at the call site. This can create timing
> side-channels if the constrained function processes sensitive data and the branch structure
> leaks information through execution time differences.

---

## Where Clauses on Types

Where clauses can appear on class, struct, and enum declarations. The constraint is checked when the
type is instantiated (for generics, at monomorphization time):

```kairo
class <T> SmallBuffer
  where sizeof(T) <= 128 {
    var data: [T; 16]
}

SmallBuffer<i32>()    // ok: sizeof(i32) == 4
SmallBuffer<[u8; 256]>()  // compile error: sizeof([u8; 256]) == 256 > 128

struct <T> Aligned16
  where alignof(T) >= 16 {
    var value: T
}

enum <T> Compact
  where sizeof(T) <= 8 {
    Some { value: T },
    None,
}
```

Where clauses are not permitted on interfaces. Interface requirements are expressed through method
signatures and generic bounds on type parameters.

---

## Where Clauses on Interface Methods

Interface method signatures can include `where` clauses. The conforming type inherits the constraint:

```kairo
interface Accumulator {
    fn add(self, value: i32) -> Self where value > 0
}

class Counter impl Accumulator {
    var total: i32

    fn Counter(self) { self.total = 0 }

    fn add(self, value: i32) -> Self where value > 0 {
        self.total += value
        return self
    }

    fn add(self, value: i32) -> Self {
        // fallback for value <= 0
        return self
    }
}
```

---

## Where Clauses in Match

The `where` keyword also appears in `match` arms as a guard condition. Match guards are always
evaluated at runtime and do not participate in the overload dispatch system they are simple
boolean filters on a matched pattern:

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

## Interaction with Other Features

### Compile-time where and `eval`

A `where` clause on an `eval` function is always evaluated at compile time. If the constraint cannot
be statically checked, the compiler emits an error:

```kairo
eval fn compute_table_size(element_size: i32) -> i32
  where element_size > 0 {
    return 1024 / element_size
}
```

See [Eval](/docs/language/eval) for compile-time evaluation rules.

### Where and `panic`

A `where` clause and `panic` serve different purposes. `where` constrains inputs before the function
body executes. `panic` signals errors from within the function body. They can coexist:

```kairo
fn parse_port(input: string) panic -> i32
  where input.len() > 0 {
    var port = std::parse<i32>(input)
    if port < 0 || port > 65535 {
        panic std::Error::Runtime("port out of range")
    }
    return port
}
```

The `where` clause filters invalid inputs. The `panic` handles valid inputs that produce errors
during processing. See [Panic](/docs/language/panic) for the panic model.

### Where and `unsafe`

`where` clauses and `unsafe` overloads are orthogonal. Safe overloads dispatch among themselves based on `where` constraints. Unsafe overloads are a separate namespace selected explicitly by the caller with the `unsafe` keyword they do not participate in `where`-based dispatch:

```kairo
// Safe version with a where constraint + its fallback
fn access(ptr: *i32, offset: i32) -> i32
  where offset >= 0 {
    return *(ptr + offset)
}

fn access(ptr: *i32, offset: i32) -> i32 { // if this doesn't exist, the compiler will error because no default candidate is available
    return 0   // safe fallback
}

// Unsafe version completely separate, caller explicitly selects it
fn access(ptr: *i32, offset: i32) unsafe -> i32 {
    return *(ptr + offset)   // no bounds check at all
}
```

See [Unsafe](/docs/language/unsafe) for the unsafe overload model.

---

## Summary

```kairo
// Compile-time constraint on a generic
fn <T> stack_alloc() -> T
  where sizeof(T) <= 4096 {
    // ...
}

// Runtime constraint with fallback dispatch
fn sqrt(x: f64) -> f64
  where x >= 0.0 {
    return std::math::sqrt(x)
}

fn sqrt(x: f64) -> f64 {
    return 0.0   // fallback for negative input
}

// Type constraint in where clause
fn <T, U> transform(input: T) -> U
  where T impl Readable && U impl Writable {
    // ...
}

// Where clause on a class
class <T> InlineBuffer
  where sizeof(T) <= 64 {
    var data: [T; 8]
}

// Multiple constrained overloads (declaration order = priority)
fn categorize(temp: f64) -> string where temp > 100.0 { return "boiling" }
fn categorize(temp: f64) -> string where temp > 0.0   { return "liquid" }
fn categorize(temp: f64) -> string                     { return "frozen" }
```

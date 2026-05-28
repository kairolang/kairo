# Closures

A closure is an anonymous function that captures variables from its enclosing scope. In Kairo, lambdas and
closures use the same syntax the only distinction is whether the function captures anything. If it does,
it's a closure. If it doesn't, it's a plain lambda.

---

## Basic Syntax

Anonymous functions are declared with `fn` followed by a parameter list, an optional return type, and a body.
The return type is inferred when omitted.

```kairo
var add = fn (a: i32, b: i32) -> i32 {
    return a + b
}

var double = fn (x: i32) -> i32 {
    return x * 2
}

add(3, 4)     // 7
double(10)    // 20
```

Closures have the same type as function pointers `fn(ParamTypes) -> ReturnType`. There is no separate
closure type:

```kairo
var op: fn(i32, i32) -> i32 = fn (a: i32, b: i32) -> i32 { return a + b }
```

---

## Capture Modes

By default, closures capture variables **by copy**. The closure receives its own copy of each captured
variable mutations inside the closure do not affect the original.

```kairo
var x = 10
var add_x = fn (y: i32) -> i32 {
    return y + x   // x is captured by copy
}

x = 999
add_x(5)   // 15 uses the copied value of x (10), not 999
```

### Capture by reference `|&|`

To capture all variables by reference, append `|&|` after the parameter list. The closure can read and modify
the original variables:

```kairo
var count = 0
var increment = fn ()|&| {
    count += 1   // modifies the original count
}

increment()
increment()
count   // 2
```

### Mixed capture `|a, &b|`

Specify capture mode per variable. Unqualified names are captured by copy, `&`-prefixed names by reference:

```kairo
var a = 10
var b = 20

var closure = fn (x: i32)|a, &b| -> i32 {
    b += 1       // modifies the original b
    return x + a + b   // a is a copy, b is a reference
}

closure(5)   // 5 + 10 + 21 = 36
a            // still 10
b            // 21
```

### Capture summary

| Syntax | Behavior |
|---|---|
| *(none)* | All captures by copy (default) |
| `\|&\|` | All captures by reference |
| `\|a, b\|` | Named variables captured by copy |
| `\|&a, &b\|` | Named variables captured by reference |
| `\|a, &b\|` | Mixed `a` by copy, `b` by reference |

---

## Default Parameters

Closures support default parameter values, matching the behavior of regular functions:

```kairo
var greet = fn (name: string = "world") {
    std::println(f"Hello, {name}!")
}

greet()          // "Hello, world!"
greet("Alice")   // "Hello, Alice!"
```

---

## Generic Closures

Closures can be generic, declaring type parameters before the parameter list:

```kairo
var identity = fn <T>(x: T) -> T {
    return x
}

identity(42)        // i32
identity("hello")   // string
```

---

## `panic` Specifier

Closures can be marked `panic` to indicate they may panic. Callers must handle the panic via
`try`/`catch`, the same as with regular functions:

```kairo
var risky = fn () panic -> i32 {
    if bad_condition {
        panic std::Error::Runtime("failed")
    }
    return 42
}

try {
    risky()
} catch e {
    std::println(f"Caught: {e}")
}
```

See [Panic](/docs/language/panic) for the full panic model.

> [!NOTE]
> Closures cannot be `async` or `eval`. Asynchronous work should use async free functions or methods.
> Compile-time evaluation requires named `eval` functions. See [Concurrency](/docs/language/concurrency)
> and [Eval](/docs/language/eval).

---

## AMT and Lifetime Safety

[AMT](/docs/language/amt) tracks closure captures the same way it tracks any other borrow. If a closure
captures a variable by reference and the closure outlives the variable, AMT will attempt to auto-promote the
capture to a smart pointer (shared, weak, or unique). If promotion is not possible, the compiler emits a
hard error.

```kairo
fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn ()|&x| -> i32 { return x }
    // AMT error: x is a stack local, closure would outlive it,
    //   and there is no safe promotion path for a stack variable
}
```

Capture by copy avoids this entirely the closure owns its own copy and has no lifetime dependency on the
original:

```kairo
fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn () -> i32 { return x }   // ok x is copied into the closure
}
```

> [!WARNING]
> Capturing stack-local variables by reference in a closure that escapes the current scope is always an AMT
> error. There is no way to promote a reference to a stack variable into a safe smart pointer. Use capture
> by copy for closures that outlive their enclosing scope.

---

## Closures vs Inner Functions

Inner functions (named functions declared inside another function) do **not** capture from the enclosing
scope they are self-contained:

```kairo
fn outer() -> i32 {
    var x = 10

    fn inner(y: i32) -> i32 = y + 1     // cannot access x inner is a plain function
    // fn inner(y: i32) -> i32 = y + x  // compile error: x is not in scope

    return inner(x)   // pass x explicitly
}
```

If you need to reference enclosing variables, use a closure. If you don't, prefer an inner function it
has no capture overhead and makes the data flow explicit.

---

## Passing Closures to Functions

Since closures share the `fn` pointer type, they can be passed to any function expecting a function pointer:

```kairo
fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x)
}

apply(fn (x: i32) -> i32 { return x * 2 }, 21)   // 42

var triple = fn (x: i32) -> i32 { return x * 3 }
apply(triple, 10)   // 30
```

Higher-order patterns work naturally:

```kairo
fn map(data: [i32], transform: fn(i32) -> i32) -> [i32] {
    var result: [i32]
    for item in data {
        result.push(transform(item))
    }
    return result
}

var doubled = map([1, 2, 3], fn (x: i32) -> i32 { return x * 2 })
// doubled == [2, 4, 6]
```

---

## Summary

```kairo
// Lambda no capture
var add = fn (a: i32, b: i32) -> i32 { return a + b }

// Closure capture by copy (default)
var x = 10
var add_x = fn (y: i32) -> i32 { return y + x }

// Closure capture all by reference
var count = 0
var inc = fn ()|&| { count += 1 }

// Closure mixed capture
var a = 1
var b = 2
var mix = fn ()|a, &b| { b += a }

// Generic closure
var id = fn <T>(x: T) -> T { return x }

// Passing closures
fn apply(f: fn(i32) -> i32, x: i32) -> i32 = f(x)
apply(fn (x: i32) -> i32 { return x * 2 }, 5)   // 10
```

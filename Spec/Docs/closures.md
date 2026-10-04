# Closures

A closure is an anonymous function that captures variables from its enclosing scope. In Kairo, lambdas and
closures use the same syntax, the only distinction is whether the function captures anything. If it does,
it's a closure. If it doesn't, it's a plain lambda.

---

## Basic Syntax

Anonymous functions are declared with `fn` followed by a parameter list, an optional return type, and a body.
The body can be a block `{ ... }` or a single expression after `=`. The return type is inferred when omitted.

```kairo
var add = fn (a: i32, b: i32) -> i32 {
    return a + b
}

var double = fn (x: i32) -> i32 = x * 2

add(3, 4)     // 7
double(10)    // 20
```

Closures have the same type as function pointers `fn(ParamTypes) -> ReturnType`. There is no separate
closure type:

```kairo
var opr: fn(i32, i32) -> i32 = fn (a: i32, b: i32) -> i32 { return a + b }
```

---

## Capture Modes

By default, closures capture variables **by copy**. The closure receives its own copy of each captured
variable, mutations inside the closure do not affect the original.

```kairo
var x = 10
var add_x = fn (y: i32) -> i32 {
    return y + x   // x is captured by copy
}

x = 999
add_x(5)   // 15, uses the copied value of x (10), not 999
```

### Capture by Pointer `|*|`

To capture all variables by pointer, append `|*|` after the parameter list. The closure can read and modify
the original variables through explicit dereference:

```kairo
var count = 0
var increment = fn ()|*| {
    *count += 1   // modifies the original count
}

increment()
increment()
count   // 2
```

### Const Pointer Capture

To capture variables by const pointer, use `|const *name, ...|` in the capture list. The closure can
read but not modify the originals:

```kairo
var x = 10
var y = 20
var z = 30

var closure = fn (a: i32)|const *x, const *y, const *z| -> i32 {
    return a + *x + *y + *z   // can read but not modify
}
```

### Mixed Capture `|a, *b|`

Specify capture mode per variable. Unqualified names are captured by copy, `*`-prefixed names by pointer:

```kairo
var a = 10
var b = 20

var closure = fn (x: i32)|a, *b| -> i32 {
    *b += 1       // modifies the original b
    return x + a + *b   // a is a copy, b is a pointer
}

closure(5)   // 5 + 10 + 21 = 36
a            // still 10
b            // 21
```

### Empty Capture List `||`

An explicit empty capture list prevents the default capture-by-copy behavior. The closure captures
nothing, any reference to an outer variable is a compile error:

```kairo
var x = 10
var no_capture = fn ()|| -> i32 {
    return 42      // ok, no outer variables referenced
}

// var bad = fn ()|| -> i32 {
//     return x    // compile error: x is not captured
// }
```

### Capture Summary

| Syntax | Behavior |
|---|---|
| *(none)* | All captures by copy (default) |
| `\|\|` | No captures allowed |
| `\|*\|` | All captures by pointer |
| `\|a, b\|` | Named variables captured by copy |
| `\|*a, *b\|` | Named variables captured by pointer |
| `\|const *a, const *b\|` | Named variables captured by const pointer |
| `\|a, *b\|` | Mixed, `a` by copy, `b` by pointer |

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

## Modifiers

Closures support the `panic`, `volatile`, and `async` modifiers. Modifiers appear after the capture list
(if present) and before the return type. Order between modifiers does not matter. A closure can also
use `-> !` to indicate it never returns.

```kairo
var risky = fn () panic -> i32 {
    if bad_condition {
        panic std::Error::Runtime("failed")
    }
    return 42
}

var side_effect = fn () volatile {}

var background = fn () async {}

var all_three = fn () volatile async panic -> i32 {
    return 100
}

var divergent = fn () panic -> ! {
    panic std::Error::Runtime("always panics")
}
```

> [!NOTE]
> Closures cannot be `eval`, `const`, `unsafe`, `virtual`, `override`, `inline`, or `final`.

See [Panic](/docs/language/panic) for the full panic model.

---

## Nested Closures

Closures can return or contain other closures, in both expression body and block body forms:

```kairo
// Expression body: outer closure returns inner closure
var nested = fn () = fn (x: i32) -> i32 = x * 2

// Block body: outer closure builds and returns inner closure
var nested_block = fn () -> fn(i32) -> i32 {
    return fn (x: i32) -> i32 { return x + 1 }
}

// Mixed: block outer, expression inner
var nested_mixed = fn () -> fn(i32) -> i32 {
    var offset = 10
    return fn (x: i32) -> i32 = x + offset
}
```

---

## Tether and Lifetime Safety

[Tether](/docs/language/tether) tracks closure captures the same way it tracks any other borrow. If a closure
captures a variable by pointer and the closure outlives the variable, Tether will attempt to auto-promote the
capture to a smart pointer (shared, weak, or unique). If promotion is not possible, the compiler emits a
hard error.

```kairo
fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn ()|*x| -> i32 { return *x }
    // Tether error: x is a stack local, closure would outlive it,
    //   and there is no safe promotion path for a stack variable
}
```

Capture by copy avoids this entirely, the closure owns its own copy and has no lifetime dependency on the
original:

```kairo
fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn () -> i32 { return x }   // ok, x is copied into the closure
}
```

> [!WARNING]
> Capturing stack-local variables by pointer in a closure that escapes the current scope is always a Tether
> error. There is no way to promote a pointer to a stack variable into a safe smart pointer. Use capture
> by copy for closures that outlive their enclosing scope.

---

## Closures vs Inner Functions

Inner functions (named functions declared inside another function) do **not** capture from the enclosing
scope, they are self-contained. Referencing an outer variable from an inner function is a compile error:

```kairo
fn outer() -> i32 {
    var x = 10

    fn inner(y: i32) -> i32 = y + 1     // ok, does not reference x
    // fn inner(y: i32) -> i32 = y + x  // compile error: x is not in scope

    return inner(x)   // pass x explicitly
}
```

If you need to reference enclosing variables by pointer, use a closure. If you don't, prefer an inner
function, it has no capture overhead and makes the data flow explicit.

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
// Lambda, no capture
var add = fn (a: i32, b: i32) -> i32 { return a + b }

// Expression body
var double = fn (x: i32) -> i32 = x * 2

// Closure, capture by copy (default)
var x = 10
var add_x = fn (y: i32) -> i32 { return y + x }

// Closure, capture all by pointer
var count = 0
var inc = fn ()|*| { *count += 1 }

// Closure, empty capture list (no captures)
var none = fn ()|| { return 42 }

// Closure, mixed capture
var a = 1
var b = 2
var mix = fn ()|a, *b| { *b += a }

// Generic closure
var id = fn <T>(x: T) -> T { return x }

// Nested closures
var nested = fn () = fn (x: i32) -> i32 = x * 2

// Modifiers
var risky = fn () panic -> i32 { return 42 }
var divergent = fn () panic -> ! { panic std::Error::Runtime("fatal") }

// Passing closures
fn apply(f: fn(i32) -> i32, x: i32) -> i32 = f(x)
apply(fn (x: i32) -> i32 { return x * 2 }, 5)   // 10
```
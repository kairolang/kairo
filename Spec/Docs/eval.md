# Compile-Time Eval

The `eval` keyword forces compile-time evaluation. An `eval` variable, function, or control flow
construct must be fully resolvable at compile time if it depends on runtime values, the compiler
emits an error. There is no "maybe compile-time, maybe runtime" mode. `eval` means compile-time,
always.

---

## Eval Variables

`eval` declares a binding whose value is computed at compile time. The result is baked into the
binary as a constant:

```kairo
eval PI = 3.14159265358979
eval MAX_BUFFER = 1024 * 1024
eval HEADER_SIZE = sizeof u32 + sizeof u16 + sizeof u8
```

`eval` bindings are implicitly `const` they cannot be reassigned. The initializer must be a
compile-time evaluable expression.

### Type annotation

Type annotations are optional. The compiler infers the type from the initializer:

```kairo
eval N = 10           // i32
eval NAME = "Kairo"   // string
eval N: u64 = 10      // explicitly u64
```

### Usage as generic arguments

`eval` variables can be used wherever a compile-time constant is required, including array sizes
and generic arguments:

```kairo
eval BUFFER_SIZE = 256

var buffer: [u8; BUFFER_SIZE] = [0; BUFFER_SIZE]

eval TABLE_WIDTH = 16
eval TABLE_HEIGHT = 16
var grid: [[f64; TABLE_WIDTH]; TABLE_HEIGHT]
```

---

## Eval Functions

An `eval` function must be fully evaluable at compile time. The compiler executes it during
compilation and replaces the call site with the result:

```kairo
eval fn factorial(n: i32) -> i32 {
    if n <= 1 { return 1 }
    return n * factorial(n - 1)
}

eval FACT_10 = factorial(10)   // computed at compile time: 3628800
```

### Calling other eval functions

Eval functions can call other eval functions:

```kairo
eval fn square(x: i32) -> i32 = x * x

eval fn sum_of_squares(n: i32) -> i32 {
    var total = 0
    for i in 1..=n {
        total += square(i)
    }
    return total
}

eval RESULT = sum_of_squares(10)   // 385
```

### Recursion

Eval functions can be recursive. The compiler evaluates the recursion at compile time:

```kairo
eval fn fib(n: i32) -> i32 {
    if n <= 1 { return n }
    return fib(n - 1) + fib(n - 2)
}

eval FIB_20 = fib(20)   // 6765
```

> [!WARNING]
> Deeply recursive eval functions can significantly increase compile times. The compiler may impose
> a recursion depth limit to prevent unbounded compilation.

---

## Restrictions

Eval bodies must be deterministic and free of side effects. The following are not permitted inside
`eval` functions or `eval` variable initializers:

| Not allowed | Reason |
|---|---|
| Heap allocation (`std::create`, `[T]` growth) | No runtime allocator at compile time |
| IO operations (file, network, console) | Side effects |
| Pointer operations (`*T`, `unsafe *T`) | No addressable memory at compile time |
| `async` / `await` / `spawn` | No runtime scheduler at compile time |
| `panic` | No runtime error handler at compile time |
| Mutable global / static variables | Side effects across evaluations |
| Calls to non-`eval` functions | Cannot guarantee compile-time evaluation |

### What is allowed

| Allowed | Examples |
|---|---|
| Arithmetic and logic | `+`, `-`, `*`, `/`, `%`, `&&`, `\|\|`, `!` |
| Comparisons | `==`, `!=`, `<`, `>`, `<=`, `>=` |
| Control flow | `if`/`else`, `for`, `while`, `loop`, `match` |
| Local variables | `var`, `const` within the eval body |
| Calling other `eval` functions | `eval fn` calls |
| `sizeof`, `alignof` | Type size queries |
| `typeof` (type position) | Compile-time type resolution |
| Struct/enum construction (trivial) | Literal aggregate initialization |
| String literals and operations | Compile-time string manipulation |
| Fixed-size arrays (`[T; N]`) | Stack-like allocation in the evaluator |

---

## Eval If

`eval if` selects a branch at compile time. The condition must be a compile-time constant. Only the
selected branch is compiled the others are discarded entirely (no codegen, no type checking):

```kairo
eval if platform == "linux" {
    fn init_platform() { /* linux-specific */ }
} else if platform == "windows" {
    fn init_platform() { /* windows-specific */ }
} else {
    fn init_platform() { /* fallback */ }
}
```

`eval if` can appear at the top level (selecting between declarations) or inside function bodies
(selecting between code paths):

```kairo
fn <T> process(x: T) -> T {
    eval if sizeof(T) <= 8 {
        return fast_path(x)
    } else {
        return slow_path(x)
    }
}
```

### Type-based branching

`eval if` combined with `typeof` enables type-specialized code paths in generic functions:

```kairo
fn <T> serialize(value: T) -> [byte] {
    eval if typeof T == i32 {
        return int_to_bytes(value)
    } else if typeof T == string {
        return value.to_bytes()
    } else {
        return generic_serialize(value)
    }
}
```

The unselected branches are not type-checked, so they can contain code that would be invalid for
the current `T`. This is the mechanism for writing type-specialized generic code without separate
overloads.

See [Control Flow](/docs/language/control-flow#compile-time-branching) for `eval if` in the context
of control flow.

---

## Eval For

`eval for` unrolls a loop at compile time when all loop bounds and operations are compile-time
evaluable:

```kairo
eval fn build_lookup_table() -> [i32; 16] {
    var table: [i32; 16]
    eval for i in 0..16 {
        table[i] = i * i
    }
    return table
}

eval SQUARES = build_lookup_table()
```

If the loop body or bounds depend on runtime values, the compiler emits an error.

> [!NOTE]
> `eval for` fully computes the loop at compile time and embeds the result. For large iteration
> counts, this increases binary size (the unrolled result is stored as data). Use regular `for`
> loops for runtime iteration.

---

## Eval and Types

`eval` works with any type that can be constructed and manipulated at compile time:

### Primitives

All integer, float, bool, char, and string types are eval-compatible:

```kairo
eval X = 42
eval PI = 3.14159
eval FLAG = true
eval INITIAL = 'K'
eval NAME = "Kairo"
```

### Fixed-size arrays

```kairo
eval PRIMES = [2, 3, 5, 7, 11, 13, 17, 19]
eval IDENTITY: [f64; 4] = [1.0, 0.0, 0.0, 1.0]
```

### Structs (trivially constructible)

```kairo
struct Point {
    var x: f64
    var y: f64
}

eval ORIGIN = Point { x: 0.0, y: 0.0 }
eval UNIT_X = Point { x: 1.0, y: 0.0 }
```

### Enums (plain)

```kairo
enum Mode { Debug, Release, Test }
eval BUILD_MODE = Mode::Release
```

### Types that are NOT eval-compatible

Classes with constructors, types with destructors, heap-allocated types (`[T]`, `{K: V}`, `{T}`),
and any type involving pointers cannot be used in `eval` context.

---

## Eval vs Const

| | `eval` | `const` |
|---|---|---|
| Evaluation time | Compile time only | Runtime (at initialization) |
| Initializer | Must be compile-time evaluable | Any expression |
| Reassignment | No | No |
| Can use in array sizes | Yes | No |
| Can use as generic argument | Yes | No |
| Heap allocation in initializer | No | Yes |
| IO in initializer | No | Yes |

`const` is an immutable binding. `eval` is a compile-time computed value. Use `const` for values
that are fixed after initialization but may depend on runtime computation. Use `eval` for values
that must be known at compile time.

```kairo
const config = load_config()          // runtime: reads a file
eval MAX_CONNECTIONS = 1024           // compile time: baked into binary
```

---

## Eval and Where Clauses

`eval` expressions are valid in `where` clauses. When a `where` clause contains only `eval`-compatible
expressions, it is checked at compile time:

```kairo
fn <T> stack_alloc() -> T
  where sizeof(T) <= 4096 {
    // guaranteed at compile time: T fits on the stack
}
```

See [Where Clauses](/docs/language/bounds) for the full constraint system.

---

## Summary

```kairo
// Eval variable
eval MAX_SIZE = 1024 * 1024
eval TABLE_SIZE = 256

// Eval function
eval fn power(base: i32, exp: i32) -> i32 {
    if exp == 0 { return 1 }
    return base * power(base, exp - 1)
}

eval TWO_TO_16 = power(2, 16)   // 65536

// Eval as array size
var buffer: [u8; MAX_SIZE]

// Eval if (platform selection)
eval if platform == "linux" {
    eval CACHE_LINE = 64
} else {
    eval CACHE_LINE = 128
}

// Eval if (type specialization)
fn <T> zero() -> T {
    eval if typeof T == i32 { return 0 }
    else if typeof T == f64 { return 0.0 }
    else if typeof T == string { return "" }
    else if typeof T == bool { return false }
}

// Eval for (compile-time loop)
eval fn sum_range(n: i32) -> i32 {
    var total = 0
    eval for i in 1..=n {
        total += i
    }
    return total
}

eval SUM_100 = sum_range(100)   // 5050
```
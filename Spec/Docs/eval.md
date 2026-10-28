# Compile-Time Eval

The `eval` keyword forces compile-time evaluation. An `eval` variable, function, or control flow construct must be fully resolvable at compile time if it depends on runtime values, the compiler emits an error. There is no "maybe compile-time, maybe runtime" mode. `eval` means compile-time, always.

---

## Eval Variables

`eval` declares a [binding](/docs/language/variables/#compile-time-constants-eval) whose value is computed at compile time. The result is baked into the binary as a constant:

```kairo
eval PI = 3.14159265358979
eval MAX_BUFFER = 1024 * 1024
eval HEADER_SIZE = sizeof u32 + sizeof u16 + sizeof u8
```

`eval` bindings are implicitly `const` they cannot be reassigned (writing `eval const` or `const eval` is accepted and means the same). The initializer must be a compile-time evaluable expression.

An `eval` binding or `eval fn` can be declared anywhere a declaration can: at file scope, inside a `module`, as a class member, or in a function body. An imported `eval` binding is a compile-time constant in the importing module too (`eval NEXT = lib::N + 1`), and so is it to C++ code that includes the module.

### Type annotation

Type annotations are optional. The compiler infers the type from the initializer:

```kairo
eval N = 10           // i32
eval NAME = "Kairo"   // string
eval N: u64 = 10      // explicitly u64
```

### Usage as generic arguments

`eval` variables can be used wherever a compile-time constant is required, including array sizes and [generic arguments](/docs/language/generics/):

```kairo
eval BUFFER_SIZE = 256

var buffer: [u8; BUFFER_SIZE] = [0; BUFFER_SIZE]

eval TABLE_WIDTH = 16
eval TABLE_HEIGHT = 16
var grid: [[f64; TABLE_WIDTH]; TABLE_HEIGHT]
```

---

## Eval Functions

An `eval` function must be fully evaluable at compile time. The compiler executes it during compilation and replaces the call site with the result:

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
> Deeply recursive eval functions can significantly increase compile times. The compiler may impose a recursion depth limit to prevent unbounded compilation.

---

## Restrictions

Eval bodies must be deterministic and free of side effects. The following are not permitted inside `eval` functions or `eval` variable initializers:

| Not allowed | Reason |
|---|---|
| Heap allocation (`@create`, `[T]` growth) | No runtime allocator at compile time |
| IO operations (file, network, console) | Side effects |
| Pointer operations (`*T`, `unsafe *T`) | No addressable memory at compile time |
| `async` / `await` / `spawn` | No runtime scheduler at compile time |
| `panic` | No runtime error handler at compile time |
| Global, static, or thread variables that are not `eval` (a `const` global is initialized at run time) | Side effects across evaluations; no value at compile time |
| Calls to non-`eval` functions | Cannot guarantee compile-time evaluation |
| Locals whose type has a non-trivial destructor | No runtime to run it at compile time |
| A `where` clause on an `eval` function | Use `requires` |

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
| String literals | `eval NAME = "Kairo"`, `NAME.len`, a `string` parameter or result of an `eval fn` (not f-strings, which format into a heap buffer) |
| Fixed-size arrays (`[T; N]`) | Stack-like allocation in the evaluator |

---

## Eval If

`eval if` selects a branch at compile time. The condition must be a compile-time constant. Only the selected branch is compiled the others are discarded entirely (no codegen, no type checking):

```kairo
eval if defined!(__linux__) {
    fn init_platform() { /* linux-specific */ }
} else if defined!(_WIN32) {
    fn init_platform() { /* windows-specific */ }
} else {
    fn init_platform() { /* fallback */ }
}
```

`eval if` can appear at the top level, in a `module` or in a class body (selecting between declarations) or inside function bodies (selecting between code paths). The declarations of the selected branch belong to the enclosing scope, exactly as if the `eval if` were not there: at file scope and in a module they are the scope's declarations, in a class body a `var` is a field and a `fn` a method, and in a function body the branch's locals are the function's.

Outside a function body the condition decides which declarations exist, so it must be evaluable before names are resolved: literals, `eval` constants (including ones an earlier `eval if` declared), `!`, `&&`, `||`, comparisons, integer arithmetic and [`defined!`](/docs/language/macros-builtin/#conditional). Calling an `eval fn` there is an error, and so is `sizeof` or `alignof`: a type's layout is not known that early. To ask for the pointer width, test the target with `defined!(__LP64__)`; to test a layout, put the `eval if` in a function body. Inside a function body a condition that depends on a generic parameter (`sizeof T`) is decided per instantiation.

```kairo
eval if defined!(__LP64__) {      // not `sizeof usize == 8`
    eval WORD_BITS = 64
} else {
    eval WORD_BITS = 32
}
```

```kairo
fn <T> process(x: T) -> T {
    eval if sizeof T <= 8 {
        return fast_path(x)
    } else {
        return slow_path(x)
    }
}
```

### Type-based branching

`eval if` combined with [`typeof`](/docs/language/type-system/#compile-time-typeof) enables type-specialized code paths in generic functions:

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

The unselected branches are not type-checked, so they can contain code that would be invalid for the current `T`. This is the mechanism for writing type-specialized generic code without separate [overloads](/docs/language/functions-overloading/).

> [!NOTE]
> Not yet: today a generic body is checked once against its bounds, so both branches are type-checked and the example above does not compile. See [Status](/docs/status/).

See [Control Flow](/docs/language/control-flow/#compile-time-branching) for `eval if` in the context of control flow.

---

## Eval For

`eval for` unrolls a loop at compile time: the body is compiled once per value, and in each copy the loop variable is a compile-time constant, so it can be tested with `eval if`:

```kairo
fn fill_squares(@inout table: [i32; 16]) {
    eval for i in 0..16 {
        table[i] = i * i        // sixteen assignments, no loop at run time
    }
}

var squares: [i32; 16]
fill_squares(&squares)
```

What an `eval for` can iterate:

| Iterable | Example |
|---|---|
| A range whose bounds are compile-time values | `eval for i in 0..N`, `eval for i in -3..=3` |
| An `eval` array, or an array literal of compile-time values | `eval for p in PRIMES` |
| A call of an `eval` generator | `eval for k in evens(10)` |

Anything else (a run-time bound, a `var` array, a generator that is not `eval`) is a compile error. `continue` and `break` work as in any loop, and so does `return` out of the enclosing function.

An `eval` generator is an `eval fn` that yields. It runs at compile time, so it can do whatever an `eval fn` can, loops and conditions included, and the `eval for` iterates the values it yielded:

```kairo
eval fn evens(n: i32) -> yield i32 {
    for var k: i32 = 0; k < n; ++k {
        if k % 2 == 0 { yield k }
    }
}

fn sum_evens() -> i32 {
    var total = 0
    eval for e in evens(10) { total += e }   // 0 + 2 + 4 + 6 + 8
    return total
}
```

An eval generator can only be iterated by an `eval for`.

In each copy the loop variable is a constant, so it can also size an array or be a generic value argument:

```kairo
eval for i in 0..3 {
    var row: [i32; i + 1]       // 1, 2, then 3 elements
    row[i] = 1
}
```

Inside an `eval fn` the whole function already runs at compile time, so an `eval for` there is an ordinary loop, and its bounds may be the function's parameters (see `sum_range` in the [Summary](#summary)).

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

A string literal is a compile-time value wherever it is used at compile time: an `eval` binding, the body of an `eval fn`, an argument of an `eval fn` called from ordinary code, a field of an eval class. An `eval fn` can take and return a `string`, and an eval class can hold one:

```kairo
eval fn greet() -> string { return "hi!" }
eval GREETING = greet()

class Config {
    pub var label: string
    eval fn Config(self, label: string) { self.label = label }
}
eval DEFAULT = Config("default")
```

An f-string is not a compile-time value: it formats into a buffer allocated at run time.

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

### Enums (plain and ADT)

```kairo
enum Mode { Debug, Release, Test }
eval BUILD_MODE = Mode::Release
```

### Types that are NOT eval-compatible

Classes with constructors that are not marked `eval`, classes and function who leak allocations across the function boundary, can not be used in `eval` context.

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

[`const`](/docs/language/variables/#constants) is an immutable binding. `eval` is a compile-time computed value. Use `const` for values that are fixed after initialization but may depend on runtime computation. Use `eval` for values that must be known at compile time.

```kairo
const config = load_config("config.toml") // runtime: reads a file
eval MAX_CONNECTIONS = 1024               // compile time: baked into binary
```

---

## Eval and Requires Clauses

`eval` expressions are valid in `requires` clauses. When a `requires` clause contains only `eval`-compatible expressions, it is checked at compile time:

```kairo
fn <T> stack_alloc() -> T
  requires sizeof T <= 4096 {
    // guaranteed at compile time: T fits on the stack
}
```

> [!WARNING]
> Using `eval` and [`where`](/docs/language/where/#what-where-cannot-do) will cause a compile error. Only `requires` based bounding is allowed in a `eval` context.

See [Requires Clauses](/docs/language/requires/) for the full constraint system.

---

## Eval in Classes

Inside a class, `eval` marks three different things:

- **An `eval` field** is a compile-time constant of the class, one value shared by every object (like a `static` field, but computed at compile time). It is read as `ClassName::NAME` and cannot be assigned.
- **An `eval` method** runs at compile time. It can be called wherever its object and arguments are compile-time values; it takes `const self` to be called on an `eval` object (an `eval` binding is const).
- **An `eval` constructor** makes the class an *eval class*: its objects can be built at compile time, so an `eval` binding can hold one. The same constructor builds an object at run time too, as long as its arguments are compile-time values.

An `eval` field can be an array length (`[i32; Grid::W]`), also for a field of its own class when its initializer is plain arithmetic over literals and constants. One whose value has to be computed by calling an `eval fn` cannot size a field of its own class: inside its own body the class is still incomplete, so the value does not exist there yet. The compiler reports it (SC116E) and offers to move the constant to module scope, where it can size the field. For the same reason, a field's length may call an `eval fn` (`var a: [i32; size()]`) only when that function does not itself need the class: one that takes `sizeof` of it, builds a local of it or is a method of it is an error.

A class can mix `eval` and regular members; regular methods simply cannot be called from compile-time code. A class with a non-trivial [destructor](/docs/language/classes-lifecycle/#destructors---delete-operators) cannot be an `eval` value: a compile-time object is never destroyed.

```kairo
eval FNV_OFFSET: u64 = 2166136261
eval FNV_PRIME: u64  = 16777619

class Hasher {
    pub eval SEED: u64 = FNV_OFFSET       // a class constant
    pub var state: u64                    // per-object state, set by the constructor

    eval fn Hasher(self, start: u64) { self.state = start }

    eval fn mix(const self, b: u64) -> u64 {
        return (self.state ^ b) * FNV_PRIME
    }
}

eval H     = Hasher(Hasher::SEED)   // a compile-time object
eval MIXED = H.mix(7)               // computed at compile time
```

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
eval if defined!(__linux__) {
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
## See also

- [Compile-time constants](/docs/language/variables/#compile-time-constants-eval)
- [Compile-time `typeof`](/docs/language/type-system/#compile-time-typeof)
- [Conditional macros](/docs/language/macros-builtin/#conditional)
- [Requires Clauses](/docs/language/requires/)
- [Generics](/docs/language/generics/)
- [Macros](/docs/language/macros/)
- [Attributes](/docs/language/attributes/)

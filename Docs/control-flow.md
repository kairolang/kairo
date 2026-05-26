# Control Flow

Kairo's control flow is block-scoped and brace-delimited. Every branch, loop, and error-handling construct
uses `{ ... }` there are no single-statement bodies. Conditions are bare expressions (no parentheses required,
though permitted for clarity).

---

## Conditionals

### `if` / `else if` / `else`

```kairo
if x > 0 {
    std::println("positive")
} else if x == 0 {
    std::println("zero")
} else {
    std::println("negative")
}
```

Braces are mandatory on all branches. The condition must evaluate to `bool` no implicit conversion from
integers or pointers.

### `if` as an expression (ternary equivalent)

Kairo has no ternary `? :` operator. Use `if`/`else` as an expression instead, the expression in each
branch is the result:

```kairo
var x = if condition { 10 } else { 20 }

var y = if a > b { a } else if a == b { 0 } else { b }
```

When used as an expression, the `else` branch is required and all branches must produce the same type. Empty
branches are not permitted in expression form.

> [!TIP]
> The compiler warns if `else if` nesting exceeds 3 levels. Consider restructuring deeply nested conditionals
> into a `switch` or separate function.

### Empty branches

Empty branches are legal in statement form. The compiler will not warn this is intentional for cases where
only one side of a conditional has work to do:

```kairo
if condition {
    // intentionally empty
} else {
    handle_false_case()
}
```

---

## `match`

`match` is Kairo's multi-way dispatch construct. It handles value matching, enum variant dispatch, ADT
destructuring, struct field extraction, and range checks all with compiler-enforced exhaustiveness.

```kairo
match status_code {
    case 200 { std::println("OK") }
    case 404 { std::println("Not Found") }
    case 500 { std::println("Internal Server Error") }
    default  { std::println(f"Unknown: {status_code}") }
}
```

### Value matching

`match` operates on integers, strings, and booleans by comparing against literal values:

```kairo
match command {
    case "start" { engine.start() }
    case "stop"  { engine.stop() }
    case "reset" { engine.reset() }
    default      { log_unknown(command) }
}

match is_valid {
    case true  { proceed() }
    case false { abort() }
}
```

### Enum variant matching

For plain enums, use the `.Variant` shorthand when the type is inferred from the match operand:

```kairo
match dir {
    case .North { go_up() }
    case .South { go_down() }
    case .East  { go_right() }
    case .West  { go_left() }
}
```

The fully qualified form `Direction::North` also works. The compiler verifies all variants are covered.

### ADT destructuring

ADT enum variants carry payloads. Destructure them in `match` with `var` or `const` bindings inside
parentheses. Field names must match the variant declaration:

```kairo
enum <K, V> LookupResult {
    Found    { key: K, value: V },
    NotFound { key: K },
    Error    { message: string },
}

match result {
    case .Found(var key, var value) {
        std::println(f"{key} = {value}")
    }
    case .NotFound(var key) {
        std::println(f"{key} not found")
    }
    case .Error(const message) {
        // message cannot be reassigned bound as const
        log_error(message)
    }
}
```

You can omit fields you do not need exhaustive field extraction is not required:

```kairo
match result {
    case .Found(var value) {
        // only value is bound, key is ignored
        process(value)
    }
    default { }
}
```

See [Enums](/docs/language/enums#adt-enums) for ADT enum declarations and construction.

### `where` guards

Append `where` followed by a boolean expression to add a condition to a case. The branch only matches
if both the pattern and the guard are satisfied:

```kairo
match result {
    case .Found(var key, var value) where value > 0 {
        std::println(f"{key} has positive value")
    }
    case .Found(var key, var value) {
        std::println(f"{key} has non-positive value")
    }
    default { }
}
```

Guards are evaluated after the pattern matches. A case with a guard that fails falls through to the
next case this is the only situation where control moves between cases.

### Struct matching

Structs have a single shape (no variants), so `match` on a struct is destructuring combined with
guards. A struct `case` without a `where` guard always matches and is a compile error unless it is
the only case or the last case (acting as a catch-all):

```kairo
struct Response {
    var status: i32
    var body: string
}

match response {
    case Response(var status, var body) where status == 200 {
        process(body)
    }
    case Response(var status) where status >= 400 {
        log_error(f"HTTP {status}")
    }
    default {
        // catch-all
    }
}
```

### Range matching

Integer cases can match a range using `..` (exclusive end) or `..=` (inclusive end):

```kairo
match http_status {
    case 200..=299 { std::println("success") }
    case 300..=399 { std::println("redirect") }
    case 400..=499 { std::println("client error") }
    case 500..=599 { std::println("server error") }
    default        { std::println("unknown") }
}
```

### `match` as an expression

Like `if`, `match` can be used as an expression. The last expression in each branch is the result value.
All branches must produce the same type:

```kairo
var label = match level {
    case .Debug   { "debug" }
    case .Info    { "info" }
    case .Warning { "warning" }
    case .Error   { "error" }
    case .Fatal   { "fatal" }
}

var priority = match code {
    case 200..=299 { 0 }
    case 400..=499 { 1 }
    case 500..=599 { 2 }
    default        { -1 }
}

var message = match result {
    case .Found(var key, var value) { f"{key}: {value}" }
    case .NotFound(var key)        { f"{key} not found" }
    case .Error(var message)       { message }
}
```

In expression form, exhaustiveness is required every possible value must be covered. For integers
and strings, this means `default` is mandatory.

### Exhaustiveness

The compiler verifies that all possible values are covered:

| Matched type | Coverage rule |
|---|---|
| Plain enum | All variants covered, or `default` present |
| ADT enum | All variants covered, or `default` present |
| Integers / strings | `default` always required |
| Booleans | `true` + `false` covers it |
| Structs | `default` always required |

A `default` case matches any value not covered by preceding cases. It must be the last case.

### No fall-through

Each case is an isolated block. There is no fall-through between cases and no `@fallthrough` attribute.
If you need multiple values to execute the same code, list them in a single case separated by commas:

```kairo
match priority {
    case 1, 2, 3 { handle_high() }
    case 4, 5    { handle_medium() }
    default      { handle_low() }
}
```

### `break` in `match` inside a loop

Inside a `match` nested within a loop, `break` exits the **loop**, not the match. Match cases are
already isolated blocks with no fall-through, so there is nothing to "break" out of within the match
itself.

```kairo
for item in items {
    match item.kind {
        case .Sentinel {
            break   // exits the for loop
        }
        case .Data(var payload) {
            process(payload)
        }
        default { }
    }
}
```

---

## Loops

### `for` range and iterator

Range-based and iterator-based `for` loops use the `in` keyword:

```kairo
for i in 0..10 {
    // i = 0, 1, 2, ..., 9
}

for i in 0..=10 {
    // i = 0, 1, 2, ..., 10
}

for item in collection {
    // iterates using the collection's fn op in (self) -> yield T
}
```

The range operators `..` and `..=` produce a `Range` object that implements the iterator protocol. Any type
that defines `fn op in (self) -> yield T` is iterable. See [Operators](/docs/language/operators#ranges) for
the `Steppable` interface and [Operators](/docs/language/operators#special-operators) for the `op in`
overload.

### Multi-variable iteration

If the collection yields tuples, destructure directly in the loop header:

```kairo
for (key, value) in some_map {
    std::println(f"{key} = {value}")
}

for (a, b) in pairs {
    // a and b are the first and second elements of each yielded tuple
}
```

The tuple arity in the loop header must match the arity yielded by the collection.

### `for` C-style

Traditional three-part `for` loops are also supported:

```kairo
for var i = 0; i < 10; i++ {
    // classic index loop
}
```

The init clause declares a new variable scoped to the loop body. The condition and step are bare expressions.

### `while`

```kairo
while condition {
    // loop body
}
```

The condition is evaluated before each iteration. No implicit conversion from integers must be `bool`.

### `loop`

`loop` is an unconditional infinite loop. It runs until an explicit `break` or `return`:

```kairo
loop {
    var input = read_line()
    if input == "quit" {
        break
    }
    process(input)
}
```

### Labeled loops

Labels allow `break` and `continue` to target a specific enclosing loop. The syntax is `label: for`/`while`/`loop`:

```kairo
outer: for i in 0..10 {
    inner: for j in 0..10 {
        if some_condition {
            break outer    // exits the outer loop entirely
        }
        if other_condition {
            continue inner // skips to next iteration of the inner loop
        }
    }
}
```

Labels follow the same naming conventions as variables (`snake_case`). `break` and `continue` without a label
target the innermost enclosing loop.

---

## `break` and `continue`

| Statement | Behavior |
|---|---|
| `break` | Exits the innermost loop |
| `break label` | Exits the loop identified by `label` |
| `continue` | Skips to the next iteration of the innermost loop |
| `continue label` | Skips to the next iteration of the loop identified by `label` |

`break` and `continue` are statements, not expressions they do not produce values. Inside a `switch`
nested within a loop, `break` exits the **loop**, not the switch (switch cases are already isolated blocks
with no fall-through by default).

---

## Error Handling

### `try` / `catch`

`try`/`catch` handles panics from functions annotated with the `panic` specifier. The compiler statically
verifies that `catch` blocks cover all panic types that can propagate from the `try` body uncovered types
are a compile error. See [Panic](/docs/language/panic) for the full panic model.

```kairo
try {
    risky_operation()
} catch {
    // catch-all any panic type
    std::println("something went wrong")
}
```

Catch blocks can filter by specific error types. The compiler checks exhaustiveness against the set of panic
types declared by the called functions:

```kairo
try {
    read_file("data.txt")
} catch e: std::Error::IO {
    std::println(f"IO error: {e}")
} catch e: std::Error::Runtime {
    std::println(f"Runtime error: {e}")
}
```

A bare `catch` (no type) acts as a catch-all and satisfies exhaustiveness for any remaining types.

### `try`/`catch` as an expression

Like `if`, `try`/`catch` can be used as an expression. The last expression in each block is the result value:

```kairo
var result = try {
    parse_int("42")
} catch e: std::Error::Runtime {
    -1   // fallback value
} catch {
    0    // default for any other error
}
```

All branches must produce the same type. `finally` is not permitted in expression form.

### `finally`

`finally` defines cleanup code that always runs whether the `try` body completes normally, panics, or
returns early.

```kairo
try {
    acquire_resource()
    do_work()
} catch e: std::Error::Runtime {
    handle_error(e)
} finally {
    release_resource()   // always executes
}
```

### Standalone `finally` (scope exit)

`finally` can also appear inside any function body without a preceding `try`. In this form, it acts as a
scope exit block the body executes when the enclosing function returns, regardless of how it exits:

```kairo
fn process_file(path: string) panic -> void {
    var fd = open(path)
    finally {
        close(fd)   // runs on normal return, panic, or early return
    }

    // ... work with fd ...
    if bad_data {
        return   // finally still runs
    }
    // ... more work ...
}
```

This is equivalent to Go's `defer` the body executes when the enclosing function exits, regardless of
how it exits (normal return, panic, or early return). Multiple `finally` blocks in the same function
execute in reverse declaration order (LIFO), matching destructor semantics.

---

## `assert`

`assert` evaluates a condition and panics if it is false. It takes an expression and an optional diagnostic
message:

```kairo
assert index < len, "index out of bounds"
assert ptr != null
```

Assert behavior is globally configurable via the `-fassert-mode` compiler flag:

| Mode | Behavior |
|---|---|
| `panic`  | Panics with the provided message or a generated diagnostic |
| `return` | Returns a default-constructed value of the function's return type |
| `log` (default) | Logs the assertion failure and continues execution |

> [!WARNING]
> `return` mode silently swallows assertion failures and produces a default-constructed value. This can
> mask bugs and produce incorrect results downstream. Use with caution `panic` mode is the default for
> a reason.

Asserts cannot appear at file scope they are only valid inside function bodies.

---

## `panic`

`panic` is a statement that triggers an unrecoverable error in the current function. Functions that can panic
must be annotated with the `panic` specifier in their signature, and the compiler enforces that callers handle
the panic via `try`/`catch`.

```kairo
fn divide(a: i32, b: i32) panic -> i32 {
    if b == 0 {
        panic std::Error::Runtime("division by zero")
    }
    return a / b
}
```

See [Panic](/docs/language/panic) for the full panic model, including `Panickable<T>`, desugaring semantics,
and the zero-cost codegen strategy.

---

## `return`

`return` exits the current function with a value. If the function returns `void`, `return` takes no operand.

```kairo
fn max(a: i32, b: i32) -> i32 {
    return if a > b { a } else { b }
}
```

## Blocks and Scope

A block is a brace-delimited sequence of statements. Every block introduces a new lexical scope variables
declared inside are not visible outside, and destructors run at the closing brace in reverse declaration
order.

```kairo
{
    var x = 42
    var y = compute(x)
    // x and y are live here
}
// x and y are destroyed and no longer accessible
```

Blocks are expressions when used as the right-hand side of a binding. The last expression in the block is
the result value:

```kairo
var result = {
    var tmp = expensive_computation()
    tmp * 2   // result = tmp * 2
}
```

Anonymous blocks are useful for limiting the lifetime of temporary resources without introducing a function:

```kairo
fn process() {
    var config = load_config()

    {
        var lock = acquire_mutex()
        // critical section
        write_shared_state(config)
    }
    // lock is destroyed here mutex released

    do_unrelated_work()
}
```

All control flow constructs (`if`, `switch`, `for`, `while`, `loop`, `try`) create implicit blocks
their bodies follow the same scoping and destruction rules.

See [Variables](/docs/language/variables#scope-and-lifetime) and [AMT](/docs/language/amt) for full lifetime semantics.

---

## Jumps

For low-level control flow (state machines, interpreters, hot loops), Kairo provides labeled jumps via
compiler intrinsics:

```kairo
label!(entry)
// ... code ...
jump!(entry)   // unconditional jump to 'entry'
```

`jump!` can only target labels within the same function cross-function jumps are a compile error. Labels
declared with `label!` are not the same as loop labels; they are raw branch targets with no structured
control flow guarantees.

> [!CAUTION]
> `jump!` bypasses destructors and `finally` blocks. Jumping over a variable's declaration and then
> referencing it is undefined behavior. Use structured control flow (`loop`, `break`, `return`) unless you
> have a concrete reason not to.

Kairo does not have a `goto` keyword. `label!` and `jump!` are compiler intrinsics surfaced with macro
syntax to make jump usage explicit and greppable in a codebase. They are not user-defined macros see
[Macros](/docs/language/macros) for the macro system.

---

## Compile-Time Branching

`eval if` selects a branch at compile time. The condition must be a compile-time constant expression if it
is not, the compiler emits an error. Only the selected branch is included in the final program; the other
branches are discarded entirely (no codegen, no type-checking).

```kairo
eval if platform == "linux" {
    fn init() { /* linux-specific init */ }
} else if platform == "windows" {
    fn init() { /* windows-specific init */ }
} else {
    fn init() { /* fallback */ }
}
```

This is equivalent to `#if` / `#elif` / `#else` in C/C++, but operates on Kairo's compile-time evaluation
system rather than a preprocessor. See [Eval](/docs/language/eval) for details on what qualifies as a
compile-time constant.

---

## Branch Hints

Kairo provides attributes to communicate branch likelihood to the compiler's optimizer. These map directly
to LLVM's branch weight metadata and `__builtin_expect` semantics in the generated code.

```kairo
@likely if hot_path {
    fast_operation()
} else {
    slow_fallback()
}

@unlikely if rare_error {
    handle_error()
}
```

| Attribute | Meaning |
|---|---|
| `@likely` | The condition is expected to be true in the common case |
| `@unlikely` | The condition is expected to be false in the common case |
| `@unreachable` | The branch should never execute if it does, behavior is undefined |

`@unreachable` is a hard assertion to the optimizer that the marked branch is dead code. If execution
reaches an `@unreachable` branch at runtime, the behavior is undefined the compiler is free to
eliminate the branch entirely and may miscompile surrounding code under that assumption.

```kairo
switch direction {
    case .North { /* ... */ }
    case .South { /* ... */ }
    case .East  { /* ... */ }
    case .West  { /* ... */ }
    @unreachable default {
        // optimizer assumes this is dead code
    }
}
```

Branch hints cannot be applied to `eval if` branches compile-time branches are resolved before codegen
and have no runtime cost to optimize.

---

## The Never Type

Functions that never return they always panic, loop forever, or call a noreturn function use `!` as
their return type:

```kairo
fn fatal(msg: string) panic -> ! {
    panic std::Error::Runtime(msg)
}

fn event_loop() -> ! {
    loop {
        process_events()
    }
}
```

`!` is the **never type**. It is a subtype of every type, meaning it can appear anywhere a value is
expected. This makes it valid in expression contexts:

```kairo
var x: i32 = if valid { compute() } else { fatal("invalid state") }
// fatal() returns ! which coerces to i32
```

See [Functions](/docs/language/functions) for return type syntax and [Type System](/docs/language/type-system) for how `!` interacts with type inference.

---

## `return`

`return` exits the current function with a value. See [Functions](/docs/language/functions) for full details
on return types, `void` returns, and expression-bodied functions.

---

## Short-Circuit Evaluation

`&&` and `||` are guaranteed left-to-right with short-circuit evaluation. The right operand is not evaluated
if the left operand determines the result:

```kairo
if ptr != null || *ptr == 42 {
    // safe: *ptr is only evaluated if ptr is non-null
}
```

This is identical to C/C++ behavior and is guaranteed by the language specification, not an optimizer artifact.

---

## Control Flow Not in Kairo

For C++ developers the following C++ constructs have no equivalent in Kairo:

| C++ Construct | Kairo Alternative |
|---|---|
| `? :` (ternary) | `if`/`else` expressions |
| `goto` | `label!` / `jump!` intrinsics |
| `do { ... } while` | `loop` with a conditional `break` at the end |
| `switch` fall-through | `match` but no fall-through |
| `throw` / C++ exceptions | `panic` / `try`/`catch` (see [Panic](/docs/language/panic)) |
| `#if` / `#ifdef` | `eval if` (see [Eval](/docs/language/eval)) |
| `constexpr` / `consteval` | `eval` functions / vars (see [Eval](/docs/language/eval)) |

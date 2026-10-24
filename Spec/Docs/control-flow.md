# Control Flow

Kairo's control flow is block-scoped and brace-delimited. Every statement-form branch, loop, and error-handling construct uses `{ ... }` there are no single-statement bodies. The value forms of `if`, `match`, and `try` write each arm as `=> expr` instead. Conditions are bare expressions (no parentheses required, though permitted for clarity).

`=>` introduces exactly one value; `{ }` after a control keyword is always a statement block.

## In this section

- [Pattern Matching](/docs/language/pattern-matching/): `match`, guards, destructuring, ranges, and exhaustiveness.

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

Braces are mandatory on all branches. The condition must evaluate to [`bool`](/docs/language/primitives/#bool) no implicit conversion from integers or pointers.

### `if` as an expression (ternary equivalent)

Kairo has no ternary `? :` operator. Use `if` as an expression instead:

```kairo
var x = if condition => 10 else => 20

var z = if a == b => 2 else if b > 2 => 1 else => 0
```

The form is `if cond => value else if cond => value else => value`. Every arm is one expression, and the final `else` is mandatory. All arms must produce the same type.

#### Arms are expressions, not blocks

A braced arm is an error ([S073E](/docs/language/diagnostics/#s073e-braced-value-arm-in-an-if-try-or-match-expression)), and the compiler offers a fix-it. An arm needs a value: `=>` with nothing after it is an error. For several statements, use a [statement expression](/docs/language/operators/#statement-expressions):

```kairo
var v = if ready => ({ var t = load(); t.normalize(); (t.value); }) else => 0
```

#### How far an arm extends

The last arm takes everything to its right that is part of the same expression:

```kairo
var z = if c => 1 else => 0 + 5     // else => (0 + 5)
```

An arm stops at `,`, `)`, `]`, `}`, and the end of the line, so call arguments work without parentheses:

```kairo
draw(if wide => 80 else => 40, height)
```

Using an `if` as the operand of an operator is legal, but it produces a warning ([S078W](/docs/language/diagnostics/#s078w-if-or-try-expression-as-an-operators-operand)). Parenthesize it:

```kairo
var w = base + (if wide => 80 else => 40)
```

#### Line breaks

You may break before or after `=>`, and before `else`:

```kairo
var z = if a == b
    => 2
    else if b > 2
    => 1
    else
    => 0
```

Inside an arm the ordinary rule applies: break after an operator, not before it.

#### Nesting

A nested `if` in any arm except the last must be in parentheses, and so must an `if` used as a condition. Otherwise it is a compile error ([S077E](/docs/language/diagnostics/#s077e-nested-if-or-try-expression-must-be-parenthesized)), and the compiler offers a fix-it. A nested `if` in the final `else` arm is allowed, but write it as `else if`: `else => if` produces a warning ([S079W](/docs/language/diagnostics/#s079w--between-else-and-if-is-redundant)).

```kairo
var r = if a => (if b => 1 else => 2) else => 3     // ok
var r = if a => if b => 1 else => 2 else => 3       // error: parenthesize the inner if
```

#### In statement position

A value-form `if` in statement position is an ordinary expression statement. Its value is discarded:

```kairo
if verbose => log_full(e) else => log_short(e)
```

> [!TIP]
> The compiler warns if `else if` nesting exceeds 3 levels. Consider restructuring deeply nested conditionals into a `match` or separate function.

### Empty branches

Empty branches are legal in statement form. The compiler will not warn this is intentional for cases where only one side of a conditional has work to do:

```kairo
if condition {
    // intentionally empty
} else {
    handle_false_case()
}
```

---

## `match`

`match` is covered in [Pattern Matching](/docs/language/pattern-matching/).

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

The range operators `..` and `..=` produce a `Range` object that implements the iterator protocol. Any type that defines `fn op in (self) -> yield T` is iterable. Defining `begin()` and `end()` on a Kairo class does not make it iterable. See [Operators](/docs/language/operators/#ranges) for the `Steppable` interface and [Operators](/docs/language/operator-overloading/#special-operators) for the `op in` overload.

An [imported C++ class](/docs/language/c-cpp-calling/) iterates the way a C++ range-based `for` does: through its member `begin()` and `end()`, or else through free `begin()` and `end()` functions found by argument-dependent lookup.

### Multi-variable iteration

If the collection yields [tuples](/docs/language/collections/#tuples-t1-t2-), [destructure](/docs/language/variables/#destructuring) directly in the loop header:

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

Labels follow the same [naming conventions](/docs/language/variables/#naming-conventions) as variables (`snake_case`). `break` and `continue` without a label target the innermost enclosing loop.

---

## `break` and `continue`

| Statement | Behavior |
|---|---|
| `break` | Exits the innermost loop |
| `break label` | Exits the loop identified by `label` |
| `continue` | Skips to the next iteration of the innermost loop |
| `continue label` | Skips to the next iteration of the loop identified by `label` |

`break` and `continue` are statements, not expressions they do not produce values. Inside a `match` nested within a loop, `break` exits the **loop**, not the match (match cases are already isolated blocks with no fall-through by default).

---

## Error Handling

### `try` / `catch`

`try`/`catch` handles panics from functions annotated with the `panic` specifier. The compiler statically verifies that `catch` blocks cover all panic types that can propagate from the `try` body uncovered types are a compile error. See [Panic](/docs/language/panic/) for the full panic model.

```kairo
try {
    risky_operation()
} catch {
    // catch-all any panic type
    std::println("something went wrong")
}
```

Catch blocks can filter by specific error types. The compiler checks exhaustiveness against the set of panic types declared by the called functions:

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

```kairo
var n = try parse(s) catch e: ParseError => -1 catch => 0
```

The form is `try operand catch ... => value`. There is no arrow after `try` itself; the operand runs until the first `catch`. Every catch arm takes one of these forms:

```kairo
var a = try f() catch => v               // catch-all
var b = try f() catch e => v             // catch-all, binds e
var c = try f() catch var e => v         // binds e as var
var d = try f() catch const e => v       // binds e as const
var g = try f() catch e: ParseError => v // only ParseError
```

A bare name after `catch` is a binding, not a type: `catch ParseError => v` binds a variable named `ParseError`. Filter by type with `catch e: T`. At least one arm is required, and a default arm must be last. All arms must produce the same type. `finally` is not permitted in expression form.

Each `catch` may start a new line:

```kairo
var n = try parse(s)
    catch e: ParseError => -1
    catch => 0
```

A bare `try {` always begins a statement-form `try`. To `try` several statements as a value, use a statement expression: `try ({ ...; (value); }) catch => ...`.

{/* TODO(docs): how to `try` a set literal or anonymous initializer as the operand. `try ({1, 2})` parses as a statement expression and is rejected (S052E), although the S073E explain text recommends it. */}

A `try` inside another `try`'s operand or arms must be parenthesized. Without the parentheses, the inner `try` would take every following `catch`:

```kairo
var n = try (try f() catch => 1) catch => 2
```

The last arm of a `try` extends as far right as it can, like the last arm of an `if`. See [How far an arm extends](#how-far-an-arm-extends).

### `finally`

`finally` defines cleanup code that always runs whether the `try` body completes normally, panics, or returns early.

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

`finally` can also appear without a preceding `try`. In this form it is a scope-exit block: its body runs when control leaves the enclosing scope, however it leaves:

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

A standalone `finally` behaves like the [destructor](/docs/language/classes-lifecycle/#destructors---delete-operators) of a local declared at the same point:

- **It is tied to the enclosing block, not the function.** A `finally` inside an `if` body or a loop body runs when that block ends. In a loop it runs at the end of every iteration that reached it.
- **It only runs if execution reached it.** A `return` or panic before the `finally` statement skips it, just as a local that was never declared is never destroyed.
- **It runs on every exit from the scope.** That includes falling off the end, `return`, `break`, `continue`, and a panic leaving the scope.
- **It runs in reverse order with everything else in the scope.** Multiple `finally` blocks and local destructors run in reverse declaration order (LIFO), so a `finally` written after a local runs before that local is destroyed.

```kairo
fn copy_all(paths: [string]) {
    for path in paths {
        var fd = open(path)
        finally {
            close(fd)   // runs at the end of each iteration, not when copy_all returns
        }
        copy(fd)
    }
}
```

This differs from Go's `defer`, which always waits for the function to return.

---

## `assert`

`assert` checks a condition. It takes an expression and an optional diagnostic message:

```kairo
assert index < len, "index out of bounds"
assert count > 0
```

What an assert does depends on the build:

| Build | Behavior |
|---|---|
| Debug | The condition is evaluated. If it is false, the program aborts with the message or a generated diagnostic |
| Release | Asserts are removed. The condition is not evaluated |

Because a release build drops the condition entirely, don't put side effects the program depends on inside an `assert`.

The `-fassert-mode` compiler flag replaces the default failure behavior:

| Mode | Behavior |
|---|---|
| `panic`  | Panics with the provided message or a generated diagnostic |
| `return` | Returns a default-constructed value of the function's return type |
| `log` | Logs the assertion failure and continues execution |

> [!WARNING]
> `return` mode silently swallows assertion failures and produces a default-constructed value. This can mask bugs and produce incorrect results downstream.

Asserts cannot appear at file scope they are only valid inside function bodies.

---

## `panic`

`panic` is a statement that triggers an unrecoverable error in the current function. Functions that can panic must be annotated with the `panic` specifier in their signature, and the compiler enforces that callers handle the panic via `try`/`catch`.

```kairo
fn divide(a: i32, b: i32) panic -> i32 {
    if b == 0 {
        panic std::Error::Runtime("division by zero")
    }
    return a / b
}
```

See [Panic](/docs/language/panic/) for the full panic model, including `Panickable<T>`, desugaring semantics, and the zero-cost codegen strategy.

---

## `return`

`return` exits the current function with a value. If the function returns `void`, `return` takes no operand.

```kairo
fn max(a: i32, b: i32) -> i32 {
    return if a > b => a else => b
}
```

## Blocks and Scope

A block is a brace-delimited sequence of statements. Every block introduces a new lexical scope variables declared inside are not visible outside, and [destructors run at the closing brace](/docs/language/ownership/#destruction-order) in reverse declaration order.

```kairo
{
    var x = 42
    var y = compute(x)
    // x and y are live here
}
// x and y are destroyed and no longer accessible
```

A plain block does not produce a value. To compute a value with statements, use a [statement expression](/docs/language/operators/#statement-expressions), whose value is its last expression:

```kairo
var result = ({
    var tmp = expensive_computation()
    tmp * 2   // result = tmp * 2
})
```

A branch of an `if` or `match` expression that needs statements can use one too.

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

All control flow constructs (`if`, `match`, `for`, `while`, `loop`, `try`) create implicit blocks their bodies follow the same scoping and destruction rules.

See [Variables](/docs/language/variables/#scope-and-lifetime) and [Tether](/docs/language/tether/) for full lifetime semantics.

---

## Jumps

For low-level control flow (state machines, interpreters, hot loops), Kairo provides labeled jumps via [compiler intrinsics](/docs/language/macros-builtin/#compiler-intrinsic-macros):

```kairo
label!(entry)
// ... code ...
jump!(entry)   // unconditional jump to 'entry'
```

`jump!` can only target labels within the same function cross-function jumps are a compile error. Labels declared with `label!` are not the same as loop labels; they are raw branch targets with no structured control flow guarantees.

> [!CAUTION]
> `jump!` bypasses destructors and `finally` blocks. Jumping over a variable's declaration and then referencing it is undefined behavior. Use structured control flow (`loop`, `break`, `return`) unless you have a concrete reason not to.

Kairo does not have a `goto` keyword. `label!` and `jump!` are compiler intrinsics surfaced with macro syntax to make jump usage explicit and greppable in a codebase. They are not user-defined macros see [Macros](/docs/language/macros/) for the macro system.

---

## Compile-Time Branching

`eval if` selects a branch at compile time. The condition must be a compile-time constant expression if it is not, the compiler emits an error. Only the selected branch is included in the final program; the other branches are discarded entirely (no codegen, no type-checking).

```kairo
eval if platform == "linux" {
    fn init() { /* linux-specific init */ }
} else if platform == "windows" {
    fn init() { /* windows-specific init */ }
} else {
    fn init() { /* fallback */ }
}
```

This is equivalent to `#if` / `#elif` / `#else` in C/C++, but operates on Kairo's compile-time evaluation system rather than a preprocessor. See [Eval](/docs/language/eval/) for details on what qualifies as a compile-time constant.

---

## Branch Hints

Kairo provides [attributes](/docs/language/attributes/#branch-hints) to communicate branch likelihood to the compiler's optimizer. These map directly to LLVM's branch weight metadata and `__builtin_expect` semantics in the generated code.

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

`@unreachable` is a hard assertion to the optimizer that the marked branch is dead code. If execution reaches an `@unreachable` branch at runtime, the behavior is undefined the compiler is free to eliminate the branch entirely and may miscompile surrounding code under that assumption.

```kairo
match direction {
    case .North { /* ... */ }
    case .South { /* ... */ }
    case .East  { /* ... */ }
    case .West  { /* ... */ }
    @unreachable default {
        // optimizer assumes this is dead code
    }
}
```

Branch hints cannot be applied to `eval if` branches compile-time branches are resolved before codegen and have no runtime cost to optimize.

---

## The Never Type

Functions that never return they always panic, loop forever, or call a noreturn function use `!` as their return type:

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

`!` is the **never type**. It is a subtype of every type, meaning it can appear anywhere a value is expected. This makes it valid in expression contexts:

```kairo
var x: i32 = if valid => compute() else => fatal("invalid state")
// fatal() returns ! which coerces to i32
```

See [Functions](/docs/language/functions/) for return type syntax and [Type System](/docs/language/type-system/) for how `!` interacts with type inference.

---

## `return`

`return` exits the current function with a value. See [Functions](/docs/language/functions/) for full details on return types, `void` returns, and expression-bodied functions.

---

## Short-Circuit Evaluation

`&&` and `||` are guaranteed left-to-right with short-circuit evaluation. The right operand is not evaluated if the left operand determines the result:

```kairo
if ptr != null && *ptr == 42 {
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
| `switch` fall-through | `match` but [no fall-through](/docs/language/pattern-matching/#no-fall-through) |
| `throw` / C++ exceptions | `panic` / `try`/`catch` (see [Panic](/docs/language/panic/)) |
| `#if` / `#ifdef` | `eval if` (see [Eval](/docs/language/eval/)) |
| `constexpr` / `consteval` | `eval` functions / vars (see [Eval](/docs/language/eval/)) |

## See also

- [Pattern Matching](/docs/language/pattern-matching/)
- [Operators](/docs/language/operators/)
- [Panic](/docs/language/panic/)
- [Eval](/docs/language/eval/)
- [Functions](/docs/language/functions/)
- [Variables](/docs/language/variables/#scope-and-lifetime)
- [Attributes](/docs/language/attributes/#branch-hints)

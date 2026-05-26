# Panic

`panic` is Kairo's error signaling mechanism. A function marked with the `panic` specifier can produce
an error instead of its declared return type. Callers must handle the error via `try`/`catch` or
propagate it by marking themselves `panic`. The compiler statically verifies that all error types are
accounted for unhandled error types are a compile error.

Unlike C++ exceptions, panics use no unwinding tables and no runtime. The codegen is zero-cost 
every panic site becomes a tagged return value checked with a branch.

---

## The `panic` Specifier

Add `panic` after the parameter list to indicate a function may produce an error:

```kairo
fn parse_port(input: string) panic -> i32 {
    if input.len() == 0 {
        panic std::Error::Runtime("empty input")
    }

    var port = std::parse<i32>(input)

    if port < 0 || port > 65535 {
        panic std::Error::Runtime("port out of range")
    }

    return port
}
```

The `panic` keyword inside the function body raises an error. The error value can be any type 
there is no base error class requirement.

---

## Handling Panics with `try`/`catch`

Callers handle panics with `try`/`catch`. The compiler tracks every error type that can propagate
from the `try` body and verifies that all types are handled:

```kairo
fn load_config(path: string) -> Config {
    var port: i32

    try {
        port = parse_port(read_file(path))
    } catch e: std::Error::Runtime {
        std::println(f"bad config: {e}")
        port = 8080
    } catch e: std::Error::IO {
        std::println(f"cannot read file: {e}")
        port = 8080
    }

    return Config(port)
}
```

### Exhaustiveness

The compiler enforces that every error type reachable from the `try` body is handled. If any type
is missing, it is a compile error unless the function is itself marked `panic`:

```kairo
fn partial_handler() panic -> i32 {
    // This function only handles Runtime errors.
    // IO errors propagate to the caller.
    try {
        return parse_and_validate()
    } catch e: std::Error::Runtime {
        return -1
    }
    // std::Error::IO is not caught propagates because this function is marked panic
}
```

A bare `catch` (no type) acts as a catch-all and satisfies exhaustiveness for all remaining types:

```kairo
fn safe_handler() -> i32 {
    try {
        return parse_and_validate()
    } catch {
        // handles any error type
        return -1
    }
}
```

### Named and unnamed catch

The error value can be bound to a variable for inspection, or the catch block can omit the binding:

```kairo
try {
    risky_operation()
} catch e: std::Error::IO {
    // e is bound can inspect the error
    log_error(e)
} catch {
    // no binding catch-all, error value is discarded
}
```

---

## Propagation

If a function calls a `panic` function without fully handling all error types, it must be marked
`panic` itself. The unhandled errors propagate to the caller:

```kairo
fn read_config() panic -> Config {
    var content = read_file("config.txt")   // may panic with IO error
    var port = parse_port(content)           // may panic with Runtime error
    return Config(port)
    // Both IO and Runtime errors propagate caller must handle them
}
```

Calling a `panic` function without `try`/`catch` and without the `panic` specifier is a compile
error:

```kairo
fn bad() -> i32 {
    return parse_port("8080")   // compile error: parse_port may panic, but bad() is not marked panic
}
```

---

## Multiple Error Types

A function does not declare which error types it can produce the compiler infers this from the
function body. A single function can panic with any number of different error types:

```kairo
fn process(path: string) panic -> Data {
    if !file_exists(path) {
        panic std::Error::IO("file not found")
    }

    var content = read_file(path)

    if content.len() == 0 {
        panic std::Error::Runtime("empty file")
    }

    if !validate(content) {
        panic std::Error::Validation("invalid format")
    }

    return parse_data(content)
}
```

Callers of `process` must handle `std::Error::IO`, `std::Error::Runtime`, and
`std::Error::Validation` (plus any errors from `read_file` and `parse_data`), or propagate them.

---

## `try`/`catch` as an Expression

`try`/`catch` can produce a value. Each branch must return the same type:

```kairo
var port = try {
    parse_port(input)
} catch e: std::Error::Runtime {
    8080
} catch {
    3000
}
```

`finally` is not permitted in expression form. See
[Control Flow](/docs/language/control-flow#trycatch-as-an-expression) for expression-form rules.

---

## `finally`

`finally` defines cleanup code that runs regardless of whether the `try` body succeeds or panics:

```kairo
try {
    acquire_lock()
    do_work()
} catch e: std::Error::Runtime {
    handle_error(e)
} finally {
    release_lock()   // always runs
}
```

### Standalone `finally` (scope exit)

`finally` can appear without a preceding `try`. In this form it runs when the enclosing function
exits, regardless of how normal return, panic, or early return:

```kairo
fn process_file(path: string) panic {
    var fd = open(path)
    finally {
        close(fd)
    }

    var data = read(fd)
    if !validate(data) {
        return   // finally still runs
    }

    transform(data)
    // finally runs here too on normal exit
}
```

Multiple `finally` blocks in the same function execute in reverse declaration order (LIFO).

See [Control Flow](/docs/language/control-flow#finally) for full `finally` semantics.

---

## Panic and No-Return (`!`)

A function with return type `!` can never return normally it always panics, loops forever, or
calls another no-return function. The `panic` specifier and `!` cannot coexist because `panic`
implies an alternative return path (the error), while `!` guarantees no return at all:

```kairo
fn fatal(msg: string) panic -> ! {
    // compile error: panic and ! are contradictory
}

fn fatal(msg: string) -> ! {
    loop { }   // ok: never returns
}
```

See [Functions](/docs/language/functions#no-return) and
[Type System](/docs/language/type-system#the-never-type-) for `!` semantics.

---

## Codegen

Panics compile to zero-cost tagged return values. There are no unwinding tables, no runtime
exception handler, and no stack unwinding. A function marked `panic` returns a tagged union
containing either the success value or an error with source location metadata.

At the call site, `try`/`catch` compiles to a branch on the tag. If the tag indicates an error,
the catch block executes. If it indicates success, the value is extracted and execution continues.

This means:

- No runtime overhead on the success path beyond a single branch (which the branch predictor
  handles efficiently)
- No stack unwinding errors propagate via normal return values
- No unwinding tables in the binary smaller executables
- All functions in Kairo are trivially `noexcept` at the ABI level

> [!NOTE]
> The `panic` statement inside a function body (`panic SomeError(...)`) does not halt the program.
> It produces the error as the function's return value. The term "panic" refers to the signaling
> mechanism, not to a crash. The program only terminates if an error reaches `main()` or the top
> level and is re-panicked with `panic e` in that context.

---

## Error Types

Kairo does not prescribe a specific error hierarchy. Any type can be used as a panic value. The
standard library provides common error types under `std::Error`:

```kairo
panic std::Error::Runtime("message")
panic std::Error::IO("message")
panic std::Error::Validation("message")
```

> [!IMPORTANT]
> The `std::Error` hierarchy is still being finalized. Detailed documentation for standard error
> types will be added in a future update.

User-defined error types work the same way:

```kairo
class ParseError {
    pub var message: string
    pub var position: i32

    fn ParseError(self, msg: string, pos: i32) {
        self.message = msg
        self.position = pos
    }
}

fn parse(input: string) panic -> Ast {
    if input.len() == 0 {
        panic ParseError("unexpected end of input", 0)
    }
    // ...
}

try {
    parse("")
} catch e: ParseError {
    std::println(f"parse error at {e.position}: {e.message}")
}
```

---

## Summary

```kairo
// Function that may panic
fn divide(a: i32, b: i32) panic -> i32 {
    if b == 0 {
        panic std::Error::Runtime("division by zero")
    }
    return a / b
}

// Full handling no panic propagation
fn safe_divide(a: i32, b: i32) -> i32 {
    try {
        return divide(a, b)
    } catch e: std::Error::Runtime {
        std::println(f"error: {e}")
        return 0
    }
}

// Partial handling propagates unhandled types
fn partial(a: i32, b: i32) panic -> i32 {
    try {
        return complex_operation(a, b)
    } catch e: std::Error::Runtime {
        return -1
    }
    // other error types propagate
}

// Expression form
var result = try { divide(10, 0) } catch { 0 }

// Scope exit
fn with_cleanup() panic {
    var resource = acquire()
    finally { release(resource) }
    do_work(resource)
}
```

# Panic

`panic` is Kairo's error signaling mechanism. A function marked with the `panic` specifier can produce an error instead of its declared return type. Callers must handle the error via `try`/`catch` or propagate it by marking themselves `panic`. The compiler statically verifies that all error types are accounted for: unhandled error types are a compile error.

Unlike [C++ exceptions](/docs/language/c-cpp-exceptions/), panics use no unwinding tables and no runtime. The codegen is zero-cost: every panic site becomes a tagged return value checked with a branch.

> [!NOTE]
> Panic is compiled. Not supported yet: a panic in a generic function (or a method of a generic type), in a generator or an `async` function, a call of a panicking operator, and keeping a caught error in another variable. See [Status](/docs/status/#not-compiled-yet).

---

## Error Types

Any type can be panicked. There is no base error class, no required shape, no required operator, and no standard error module: an error type is an ordinary struct, class or enum. The type only has to be movable (an error is returned and propagated by value), and it must be a value type, not a reference or `void`.

An error type may define [`op panic`](/docs/language/operator-overloading/#op-panic) to give itself a human-readable message:

```kairo
struct ParseError {
    var message: string
    var position: i32

    fn op panic (const self) -> string {
        return f"{self.message} at {self.position}"
    }
}
```

`op panic` is optional. It takes `const self` and returns `string`. A panic can never reach `main` unhandled, so Kairo itself never needs an error's message; the message is shown only on the C++ side, where [`value_or_throw`](/docs/language/c-cpp-exceptions/#converting-to-an-exception) turns an error into an exception whose `what()` uses it. Without `op panic`, `what()` gives the type name and source location instead. Raising, propagating and catching an error never call it.

- Panicking a type that isn't movable is a compile error, at the `panic`, at a [declared set](#declared-panic-sets) or at a `catch e: T` that names it.
- A type you don't own (a primitive, another module's type) can get `op panic` from an [`extend`](/docs/language/extends/).
- A C++ type can be panicked too: it is just a value. It can't define a Kairo operator, so its `what()` is always the type name and location. Catching C++ *exceptions* is a separate mechanism; see [Exceptions](/docs/language/c-cpp-exceptions/#exceptions).

The examples on this page use these error types and functions:

```kairo
struct IOError {
    var path: string
    fn op panic (const self) -> string { return f"cannot read {self.path}" }
}

struct RangeError {
    var value: i32
    fn op panic (const self) -> string { return f"{self.value} is out of range" }
}

struct EmptyInput {
    fn op panic (const self) -> string { return "empty input" }
}

fn read_file(path: string) panic(IOError) -> string { /* ... */ }
fn parse_and_validate() panic(RangeError, IOError) -> i32 { /* ... */ }
```

---

## The `panic` Specifier

Add `panic` after the parameter list to indicate a function may produce an error:

```kairo
fn parse_port(input: string) panic -> i32 {
    if input.length() == 0 {
        panic EmptyInput {}
    }

    var port = std::parse<i32>(input)

    if port < 0 || port > 65535 {
        panic RangeError { value: port }
    }

    return port
}
```

The `panic` statement inside the function body raises an error. The function's **panic set**, the error types it can produce, is inferred from its body: here `EmptyInput` and `RangeError`, plus whatever `std::parse` can propagate. To fix the set instead of inferring it, write it out: see [Declared Panic Sets](#declared-panic-sets).

---

## Handling Panics with `try`/`catch`

Callers handle panics with `try`/`catch`. The compiler tracks every error type that can propagate from the `try` body and verifies that all types are handled:

```kairo
fn load_config(path: string) -> Config {
    var port: i32

    try {
        port = parse_port(read_file(path))
    } catch e: IOError {
        std::println(f"cannot read file: {e.path}")
        port = 8080
    } catch e: RangeError {
        std::println(f"bad port: {e.value}")
        port = 8080
    } catch {
        port = 8080   // EmptyInput, and anything std::parse propagates
    }

    return Config(port)
}
```

### Exhaustiveness

The compiler enforces that every error type reachable from the `try` body is handled. If any type is missing, it is a compile error unless the function is itself marked `panic`:

```kairo
fn partial_handler() panic -> i32 {
    // This function only handles RangeError.
    // IOError propagates to the caller.
    try {
        return parse_and_validate()
    } catch e: RangeError {
        return -1
    }
    // IOError is not caught: it propagates because this function is marked panic
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
} catch e: IOError {
    // e is bound: can inspect the error
    log_error(e.path)
} catch {
    // no binding: catch-all, error value is discarded
}
```

A catch-all can bind the error too: `catch e` holds whichever error the earlier arms did not catch. It can be re-panicked with `panic e`, which keeps the original source location. Holding it in another variable (`var copy = e`) is not supported yet.

### Arms match exact types

A panic set is a set of **exact types**. There is no subtyping between error types: `catch e: Base` does not catch a panic whose type is a class derived from `Base`, and a set that holds both `Base` and `Derived` holds two distinct types, each caught by its own arm.

```kairo
class NetError {
    fn op panic (const self) -> string { return "network error" }
}

class TimeoutError derives NetError {
    fn op panic (const self) -> string { return "timed out" }
}

fn fetch() panic -> string {               // set: TimeoutError
    panic TimeoutError()
}

try {
    fetch()
} catch e: NetError {                      // warning: NetError is not in the set; this arm never runs
    // ...
} catch e: TimeoutError {                  // this arm catches it
    // ...
}
```

> [!IMPORTANT]
> This differs from C++, where `catch (const Base&)` also catches every derived exception. In Kairo each arm names one exact type, which keeps the dispatch a single compare per arm.

### Dead arms and arm order

- A `catch e: T` whose `T` is not in the `try` body's set can never run. It is a **warning**, with a fix-it removing the arm, not an error: a library that removes an error from a function's set must not break every caller that still catches it.
- Two arms for the same type are an error.
- Any arm after a bare `catch` is an error: the bare `catch` has already handled everything.

---

## Propagation

If a function calls a `panic` function without fully handling all error types, it must be marked `panic` itself. The unhandled errors propagate to the caller:

```kairo
fn read_config() panic -> Config {
    var content = read_file("config.txt")   // may panic with IOError
    var port = parse_port(content)           // may panic with EmptyInput or RangeError
    return Config(port)
    // all of them propagate: the caller must handle them
}
```

Calling a `panic` function without `try`/`catch` and without the `panic` specifier is a compile error. The error names every unhandled type; the fix-its add `panic` to the caller or wrap the call in `try`:

```kairo
fn bad() -> i32 {
    return parse_port("8080")   // compile error: parse_port may panic, but bad() is not marked panic
}
```

### Re-panic

Inside a `catch` arm, `panic e` propagates the caught error to the caller, and its type joins the function's set. The error keeps its **original source location**: the site it reports is where it was first panicked, not the re-panic.

```kairo
fn load() panic -> i32 {
    try {
        return parse_and_validate()
    } catch e: RangeError {
        return -1
    } catch e: IOError {
        log_error(e.path)
        panic e                   // still reports the site inside read_file
    }
}
```

---

## Multiple Error Types

A single function can panic with any number of different error types. Without a declared set, the compiler infers the set from the function body:

```kairo
struct FormatError {
    var line: i32
    fn op panic (const self) -> string { return f"invalid format on line {self.line}" }
}

fn process(path: string) panic -> Data {
    if !file_exists(path) {
        panic IOError { path: path }
    }

    var content = read_file(path)

    if content.length() == 0 {
        panic EmptyInput {}
    }

    if !validate(content) {
        panic FormatError { line: 1 }
    }

    return parse_data(content)
}
```

Callers of `process` must handle `IOError`, `EmptyInput` and `FormatError` (plus any errors from `parse_data`), or propagate them.

The order of the `panic` statements does not matter. A set is unordered: two sets holding the same types are the same set.

---

## Declared Panic Sets

`panic(E1, E2)` names the set instead of inferring it. Library authors use it to pin their contract:

```kairo
fn load_port(path: string) panic(IOError, RangeError) -> i32 {
    var text = read_file(path)          // IOError: in the set
    return parse_port(text)             // compile error: 'EmptyInput' is not in the declared panic set of 'load_port'
}
```

Anything panicked or propagated outside the declared set is a compile error, labelled at the `panic` or at the propagating call, with a fix-it adding the type to the list.

The list is written right after `panic`, on the same line, wherever the specifier goes: after a function's or closure's parameter list, and after a function type's. There it is always the set, never a tuple. A line break ends the specifier, and in a function body `panic (x)` is the [`panic` statement](#the-panic-specifier) with a parenthesized value. A set names at least one type: `panic()` is an error whose fix-it removes the parentheses, leaving a bare `panic`.

```kairo
fn f() panic(IOError) -> (i32, i32)   // the set, then a tuple return type

fn g() panic -> i32 {
    panic (IOError { path: "x" })     // the statement, with a parenthesized value
}
```

### Where a declared set is required

A bare `panic` is enough on an ordinary function. A declared set is **required** in four positions, and a bare `panic` there is an error whose fix-it writes the inferred set:

| Position | Why |
|---|---|
| A [function type](/docs/language/functions/#function-pointers): `fn(string) panic(IOError) -> i32` | It has no body to infer from |
| An [interface requirement](/docs/language/interfaces-requirements/#panicking-requirements) | No body, and it is a contract for every conformer |
| A [`virtual`](/docs/language/classes-inheritance/#virtual-dispatch) method of a base class | A contract for every override |
| A [closure](/docs/language/closures/#modifiers): `fn () panic(IOError) -> i32 { ... }` | A readability rule: the set is visible where the closure is written |

```kairo
interface Loader {
    fn load(self, path: string) panic(IOError) -> string
}

fn run(f: fn(string) panic(IOError, RangeError) -> i32) panic -> i32 { return f("port.txt") }

var retry = fn () panic(IOError) -> string { return read_file("data.txt") }
```

### Subsets

- An `override` may leave its set inferred, but the set must be a subset of the base method's.
- A conforming method's set must be a subset of the interface requirement's.
- A function whose set is `S` converts to a function type whose set is `S'` only when `S` is a subset of `S'`. A function that doesn't panic converts to any panicking function type.
- A function used as a value (passed, stored, assigned) must declare its set: the value's type carries the set, and an inferred set is only known once the whole program is checked. The compiler's fix-it writes the inferred set.

### Public functions

An inferred set on a `pub` function is API surface that changes silently when the body changes. When building a library, the compiler warns about a `pub` function whose set is inferred, with a fix-it that writes the set out. The warning is off for executables.

---

## Try/Catch as an Expression

```kairo
var port = try parse_port(input)
    catch e: RangeError => 8080
    catch => 3000
```

`try`/`catch` can produce a value. Each arm is `catch ... => value`, and every arm must produce the same type. `finally` is not permitted in expression form.

An arm may also leave instead of producing a value: `return` from the enclosing function, or `break` / `continue` out of an enclosing loop. Such an arm has type [`!`](/docs/language/type-system/#the-never-type-), so it fits beside arms of any type:

```kairo
fn port_or_default(input: string) -> i32 {
    var port = try parse_port(input) catch => return 3000
    return port
}
```

Inside a closure, `return` leaves the closure, as everywhere.

See [Control Flow](/docs/language/control-flow/#trycatch-as-an-expression) for the `=>` arm rules: arm forms, line breaks, and nesting.

---

## Finally

`finally` defines cleanup code that runs regardless of whether the `try` body succeeds or panics:

```kairo
try {
    acquire_lock()
    do_work()
} catch e: IOError {
    handle_error(e)
}

finally { // identical to standalone `finally`
    release_lock()   // always runs
}
```

### Standalone `finally` (scope exit)

`finally` can appear without a preceding `try`. In this form it runs when control leaves the enclosing scope, however it leaves: normal exit, `return`, `break`, `continue`, or a panic:

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

A standalone `finally` behaves like the [destructor](/docs/language/classes-lifecycle/#destructors---delete-operators) of a local declared at the same point. It belongs to its enclosing block rather than the function, runs only if execution reached it, and runs in reverse declaration order (LIFO) together with the scope's destructors.

See [Control Flow](/docs/language/control-flow/#finally) for full `finally` semantics.

---

## `main` and `crash!`

`main` can never panic:

- `fn main() panic` is a compile error.
- A panic that would reach `main` unhandled is a compile error, naming each unhandled type and the call that propagates it. Every error is handled in `main` or below it.
- A [script](/docs/language/modules/#scripts)'s top-level code follows the same rule: it must handle every panic.

To stop the program, call `crash!()`. It terminates the process and never returns. It is not a panic: it is in no set and cannot be caught.

```kairo
fn main() -> i32 {
    var port = try parse_and_validate() catch => crash!()
    return serve(port)
}
```

`crash!("why")` writes `why` and a newline to stderr, then aborts; `crash!()` writes nothing. The rest of the crash family ends the program the same way, each with a message the compiler builds (what failed and its `file:line:col`): `unwrap!` on null, a failed checked `as` into a closed enum, and a failed [asserting downcast](/docs/language/casting/#downcasting-base-to-derived) `p as *D`.

> [!NOTE]
> A crash runs on a program that is already broken, so it does only what a signal handler may: one `write` of an already-built message (at most 4096 bytes) to stderr, then `abort()`, with any `SIGABRT` handler the program installed reset first. No allocation, no locks, no Kairo code runs. `crash!` is a macro defined in the builtin library ([what it may do](/docs/language/macros-builtin/)).

---

## Panic and No-Return (`!`)

A function with return type `!` can never return normally: it crashes, loops forever, or calls another no-return function. The `panic` specifier and `!` cannot coexist, because `panic` implies an alternative return path (the error), while `!` guarantees no return at all:

```kairo
struct FatalError {
    var message: string
    fn op panic (const self) -> string { return self.message }
}

fn fatal(msg: string) panic -> ! {
    // compile error: panic and ! are contradictory
    panic FatalError { message: msg } // invalid, panic implies an error return, but ! means no return at all
}

fn fatal(msg: string) -> ! {
    std::println(msg)
    crash!() // valid: never returns
}
```

See [Functions](/docs/language/functions/#no-return-) and [Type System](/docs/language/type-system/#the-never-type-) for `!` semantics.

---

## What Is Not a Panic

Some failures stop the program instead of producing an error value. None of them is in a panic set, and none can be caught:

- `crash!()`.
- [`unwrap!`](/docs/language/nullables/) on a null value.
- A failing [asserting downcast](/docs/language/casting/#downcasting-base-to-derived), `p as *Derived`. The compiler warns on every asserting downcast and suggests the checked form `p as *Derived?`, which yields null instead.

A bad cast or a null unwrap is a programmer error, not a recoverable condition. Making it a panic would add an error type to every function that downcasts, and to every caller above it.

---

## Where Panics Are Not Allowed

- **Global initializers.** A `panic`, a `try`, or a call to a panicking function in the initializer of a global variable is a compile error: there is no function for the error to propagate to. A [script](/docs/language/modules/#scripts)'s top-level variables are initialized as part of its top-level code, so they may use `try`.
- **Constructors and destructors.** No constructor or destructor can panic, and no panic may escape one: handle it inside, or stop with `crash!()`. Construction that can fail belongs in a static factory function. See [Class Lifecycle](/docs/language/classes-lifecycle/#constructors-and-destructors-never-panic).
- **`eval` functions.** `panic` in a function evaluated at compile time is an error. See [Eval](/docs/language/eval/).
- **Generators and `async`.** For a [generator](/docs/language/functions-generators/) or an [`async`](/docs/language/concurrency/) function, an error surfaces where the caller resumes it: at the `next()` call (including the hidden one in a `for` loop) or the `await`, which handles or propagates it like any other panicking call. A `panic`, or a panicking call, inside a generator or `async` body is not supported yet.
- **Generic functions.** A generic function's set can depend on its type arguments, so it will be inferred per instantiation. Not supported yet ([SC116E](/docs/language/diagnostics/#sc116e-a-feature-is-not-yet-supported)): a generic `panic` function, a `panic` method of a generic type, and a `panic` or a panicking call inside a generic body.

---

## Codegen

Panics compile to zero-cost tagged return values. There are no [unwinding tables](/docs/language/attributes/#unwinding), no runtime exception handler, and no stack unwinding. A function marked `panic` returns a tagged union holding either the success value or one of the errors in its set, together with the source location where the error was raised. Every Kairo function, panicking or not, stays `noexcept` in its generated C++.

At a call site, the compiler tests the tag where the call is, so arguments still run left to right and a call on the right of `&&` or `||` still runs only when that side is evaluated. On success, execution continues with the value. An error the caller doesn't handle is returned to its own caller as it is, keeping its tag and source location; the payload is moved, or copied as raw bytes when the two results have the same layout. A call in tail position (`return g()`) needs no test at all.

`try`/`catch` lowers to one tag compare per `catch` arm, in order, with a bare `catch` as the final fallback, and a catch binding refers to the error in place. An error type's tag is the same in every set that contains it, so passing an error up through callers with larger sets never translates it. When a `try` body holds a single panicking call, the arms read that call's result directly. With more than one, the first error is moved into storage that is only ever built on the error path, and moved out again before any arm runs, so every way of leaving an arm (falling through, `return`, `break`, `continue`, a re-panic) destroys it exactly once.

An override of a `virtual` method returns its base method's result type, whatever its own (smaller) set: callers through the base and through the derived type see one function. A function value whose type allows more errors than the function it holds (or any, when the function cannot panic) is wrapped where it is converted.

This means:

- No runtime overhead on the success path beyond a single branch (which the branch predictor handles efficiently)
- No stack unwinding: errors propagate via normal return values
- No unwinding tables for panics: smaller executables
- No Kairo function throws; only a C++ exception can unwind through Kairo code

> [!NOTE]
> The same `try`/`catch` syntax can also catch an exception thrown by C++ code called inside the `try` (`catch e: cxx::std::exception`). That path does use the platform unwinder: the `try` becomes a C++ `try` inside the still-`noexcept` function. See [Exceptions](/docs/language/c-cpp-exceptions/#c-to-kairo) in C/C++ Interop.
>
> C++ code calling a panicking Kairo function gets the tagged union by value and reads it with `::builtin::ok`, `value`, `is<E>`, `error<E>` and `site`, or converts it to an exception with `::builtin::value_or_throw`. See [Kairo to C++](/docs/language/c-cpp-exceptions/#kairo-to-c-kairo-never-throws).

> [!NOTE]
> The `panic` statement inside a function body (`panic SomeError { ... }`) does not halt the program. It produces the error as the function's return value. The term "panic" refers to the signaling mechanism, not to a crash. Because an error can never reach `main` unhandled, a panic never terminates the program; [`crash!`](#main-and-crash) does.

### Performance: keep error types small

The result of a panicking function is returned in registers only while it is at most 16 bytes (on x86-64): an 8-byte header holding the tag and the source location, plus the largest of the return type and the error types in its set. When every payload is at most 8 bytes, the result travels in two registers.

One large error type in a set changes that for every function whose result has that set: they all return through memory. That is correct, only slower. The compiler emits a remark when a result type exceeds 16 bytes, naming the payload that pushed it over. To keep a large error cheap, store its bulky part behind a pointer, or give the detailed context its own error type that only cold paths produce.

---

## Summary

```kairo
// An error type: any movable type (op panic gives it a message)
struct DivideByZero {
    fn op panic (const self) -> string { return "division by zero" }
}

// Function that may panic; its set is inferred: DivideByZero
fn divide(a: i32, b: i32) panic -> i32 {
    if b == 0 {
        panic DivideByZero {}
    }
    return a / b
}

// A declared set
fn checked_divide(a: i32, b: i32) panic(DivideByZero) -> i32 = divide(a, b)

// Full handling: no panic propagation
fn safe_divide(a: i32, b: i32) -> i32 {
    try {
        return divide(a, b)
    } catch e: DivideByZero {
        std::println("error: division by zero")
        return 0
    }
}

// Partial handling: propagates unhandled types
fn partial() panic -> i32 {
    return try parse_and_validate()
        catch e: RangeError => -1
    // IOError propagates
}

// Expression form, and an arm that leaves
fn expression_forms(s: string) -> i32 {
    var result = try divide(10, 0) catch => 0
    var port = try parse_port(s) catch => return result
    return port
}

// A closure declares its set
var risky = fn () panic(DivideByZero) -> i32 { return divide(1, 0) }

// Scope exit
fn with_cleanup() panic {
    var resource = acquire()
    finally { release(resource) }
    do_work(resource)
}

// Stopping the program
fn main() -> i32 {
    return try partial() catch => crash!()
}
```

## See also

- [Control Flow](/docs/language/control-flow/#error-handling)
- [Assert](/docs/language/control-flow/#assert)
- [Operator Overloading: `op panic`](/docs/language/operator-overloading/#op-panic)
- [Exceptions & Panics](/docs/language/c-cpp-exceptions/)
- [Unwinding](/docs/language/attributes/#unwinding)
- [Requires and Panic](/docs/language/requires/#requires-and-panic)
- [Where and Panic](/docs/language/where/#where-and-panic)
- [Closure Modifiers](/docs/language/closures/#modifiers)
- [Diagnostics](/docs/language/diagnostics/)

# Functions

Functions in Kairo follow a consistent declaration syntax for both free functions and class methods. The full
grammar covers visibility, ABI linkage, generics, modifiers, bounds, and return types all optional except
the `fn` keyword, the name, and the parameter list.

---

## Declaration Syntax

```kairo
fn name(param1: Type1, param2: Type2) -> ReturnType {
    // body
}
```

The full grammar:

```bnf
function_declaration ::= visibility? abi_mod? "fn" generics? identifier
                         "(" parameter_list? ")" function_mods? "->" return_type? bounds? block

visibility   ::= "pub" | "priv" | "prot"
abi_mod      ::= ("ffi" string_literal) | "static" | "virtual" | "override"
generics     ::= "<" generic_param_list ">"
function_mods ::= "const" | "volatile" | "unsafe" | "eval" | "async" | "final" | "panic" | "inline"
bounds       ::= "where" expression
return_type  ::= type | "!"
```

All parts except `fn`, the name, and the parenthesized parameter list are optional. When the return type is
omitted, it defaults to `void`.

---

## Parameters

Parameters are declared as `name: Type`. Each parameter requires an explicit type annotation there is no
parameter type inference.

```kairo
fn greet(name: string, loud: bool) {
    if loud {
        std::println(f"HELLO, {name}!")
    } else {
        std::println(f"Hello, {name}.")
    }
}
```

### Default parameters

Parameters can have default values. When a caller omits a defaulted argument, the default is used:

```kairo
fn greet(name: string = "world") {
    std::println(f"Hello, {name}!")
}

greet()          // "Hello, world!"
greet("Alice")   // "Hello, Alice!"
```

Defaults are evaluated at the call site. Parameters with defaults must appear after non-defaulted parameters.

### Named arguments

Arguments can be passed by name at the call site. Positional arguments must come before named arguments,
matching C++ conventions:

```kairo
fn create_user(name: string, age: i32 = 18, country: string = "USA") -> User {
    return User { name, age, country }
}

create_user("Alice")                              // age=18, country="USA"
create_user("Bob", 25)                            // country="USA"
create_user(name: "Eve", country: "UK")           // age=18
create_user("Grace", 22)                          // country="USA"
create_user(name: "Frank", age: 30, country: "CA") // all explicit
```

---

## Return Types

### Explicit return

```kairo
fn add(a: i32, b: i32) -> i32 {
    return a + b
}
```

### Implicit `void`

When no return type is specified, the function returns `void`:

```kairo
fn log(msg: string) {
    std::println(msg)
}

fn log_explicit(msg: string) -> void {   // equivalent
    std::println(msg)
}
```

### No-return `!`

Functions that never return they always panic, loop forever, or call a no-return function use `!` as
their return type:

```kairo
fn fatal(msg: string) -> ! {
    std::println(f"Fatal: {msg}")
    std::crash(1)
}

fn event_loop() -> ! {
    loop {
        process_events()
    }
}
```

`!` is the **no-return type**. It is a subtype of every type, meaning it can appear anywhere a value is
expected:

```kairo
var x: i32 = if valid { compute() } else { fatal("bad state") }
// fatal() returns ! which coerces to i32
```

> [!WARNING]
> No-return functions cannot have a `panic` specifier. Since `panic` acts as an alternative return path, it
> contradicts the guarantee that the function never returns. The compiler rejects `fn f() panic -> !`.

### Special return types

These return type modifiers interact with Kairo's concurrency and type system. Each is covered in detail on
its respective page:

| Return type | Description | Details |
|---|---|---|
| `yield T` | Coroutine yields values of type `T` cooperatively | [Concurrency](/docs/language/concurrency) |
| `atomic T` | Atomic wrapper thread-safe operations | [Concurrency](/docs/language/concurrency) |
| `thread T` | Thread-local storage | [Concurrency](/docs/language/concurrency) |

```kairo
fn generate_numbers() -> yield i32 {
    for i in 0..10 {
        yield i   // yield, not return function must have a yield return type
    }
}
```

> [!NOTE]
> Functions with a `yield` return type cannot use `return` to produce values only `yield`. A bare `return`
> (no operand) is permitted to terminate the coroutine early.

---

## Expression-Bodied Functions

Single-expression functions can use the `=` shorthand, omitting braces and `return`:

```kairo
fn add(a: i32, b: i32) -> i32 = a + b

fn square(x: f64) -> f64 = x * x

fn greeting(name: string) -> string = f"Hello, {name}!"
```

---

## `return`

`return` exits the current function with a value. For `void` functions, `return` takes no operand.

```kairo
fn max(a: i32, b: i32) -> i32 {
    if a > b {
        return a
    }
    return b
}

fn log(msg: string) {
    std::println(msg)
    return   // explicit return from void function valid but optional
}
```

Early returns are permitted anywhere in a function body. The compiler verifies that all code paths return a
value of the declared return type.

---

## Function Overloading

Functions can be overloaded by parameter types, matching C++ overload resolution rules:

```kairo
fn add(a: i32, b: i32) -> i32 = a + b
fn add(a: f64, b: f64) -> f64 = a + b
fn add(a: string, b: string) -> string = a + b
```

### Unsafe overloads

The `unsafe` modifier creates a separate overload in its own namespace. Safe and unsafe versions of the same
function coexist the caller explicitly selects which one to invoke:

```kairo
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

fn add(a: i32, b: i32) unsafe -> i32 {
    return a << 1 + b << 1   // faster but semantically different
}

var x = add(10, 20)          // calls the safe version
var y = unsafe add(10, 20)   // calls the unsafe overload
```

> [!NOTE]
> `unsafe` overloads are not "unsafe memory" AMT still guarantees memory safety. The `unsafe` qualifier
> signals that the function may not uphold other invariants that the safe version does. See
> [Unsafe](/docs/language/unsafe) for the full unsafe model.

### `const` overloading restriction

`const` and non-`const` methods with the same name and parameter types cannot coexist. They live in the same
scope use distinct names like `get()` and `get_mut()` instead:

```kairo
class Foo {
    fn bar(const self) -> i32 { return 42 }
    fn bar(self) -> i32 { return 24 }               // compile error: cannot overload const
    fn bar(const self, a: i32) -> i32 { return a }  // ok: different parameter list ok
}
```

---

## Variadic Functions

The `...` prefix on a parameter name accepts an arbitrary number of arguments of the same type. The parameter
is accessible as a tuple inside the function body:

```kairo
fn sum(...numbers: i32) -> i32 {
    var total = 0
    for num in numbers {
        total += num
    }
    return total
}

sum(1, 2, 3)        // 6
sum(10, 20, 30, 40) // 100
```

### Generic variadic functions

Combine `...` with generic type packs to accept arguments of different types:

```kairo
fn <...T> print_all(...args: T) {
    for arg in args {
        std::println(arg as string)
    }
}

print_all(42, "hello", true)   // prints each on a new line
```

The parameter is a tuple of heterogeneous types. Each element in the pack must satisfy the constraints used
in the function body in the example above, every `T` must be convertible to `string` via `as`.

---

## Generic Functions

Generic functions declare type parameters in angle brackets before the function name:

```kairo
fn <T> identity(x: T) -> T {
    return x
}
```

Constrain type parameters with `impl` (interface conformance) or `derives` (class inheritance):

```kairo
fn <T impl Comparable> max(a: T, b: T) -> T {
    return if a > b { a } else { b }
}

fn <T derives Serializable> serialize(value: T) -> [byte] {
    return value.to_bytes()
}
```

> [!NOTE]
> `impl` checks structural conformance the type satisfies the interface's required method signatures
> without needing an explicit `impl` declaration. `derives` checks polymorphic inheritance the type is a
> subclass of the specified class. See [Interfaces](/docs/language/interfaces) and
> [Bounds](/docs/language/bounds) for details.

### `where` clauses

For constraints beyond type parameter bounds, use a `where` clause:

```kairo
fn <T impl ToString> print_value(value: T) where T.value == "MyThing" {
    std::println(value as string)
}
```

`where` conditions are evaluated at compile time when possible the branch is eliminated entirely. When the
condition depends on runtime values, the function becomes conditionally callable and the compiler inserts a
check at the call site. See [Bounds](/docs/language/bounds) for the full constraint system.

---

## Function Modifiers

Modifiers appear after the parameter list and before the return type arrow. Multiple modifiers can be
combined, subject to the compatibility rules below.

```kairo
fn compute(x: i32) const inline -> i32 { return x * x }
fn dangerous() unsafe -> void          { /* ... */ }
fn compile_time() eval -> i32          { return 42 }
fn may_fail() panic -> i32             { /* ... */ }
fn background() async -> Data          { /* ... */ }
```

### Modifier reference

| Modifier | Free functions | Methods | Description |
|---|---|---|---|
| `const` | | Yes | Method does not modify `self`. See [Variables](/docs/language/variables#the-const-binding-rule) |
| `volatile` | Yes | Yes | Prevents certain compiler optimizations; for hardware interaction |
| `unsafe` | Yes | Yes | Separate overload namespace for alternative implementations |
| `eval` | Yes | Yes | Must be evaluable at compile time. See [Eval](/docs/language/eval) |
| `async` | Yes | Yes | Asynchronous execution. See [Concurrency](/docs/language/concurrency) |
| `panic` | Yes | Yes | May panic; callers must handle. See [Panic](/docs/language/panic) |
| `inline` | Yes | Yes | Hint to inline at call sites |
| `final` | | Yes | Prevents override in subclasses. See [Classes](/docs/language/classes) |

### Modifier compatibility

Not all modifiers can be combined:

| Combination | Valid | Reason |
|---|---|---|
| `const` + `volatile` | ok: | |
| `const` + `unsafe` | | `unsafe:` implies a separate overload with different invariants |
| `const` + `eval` | | `eval:` implies compile-time evaluation `const self` is meaningless |
| `const` + `async` | ok: | |
| `unsafe` + any other | ok: | `unsafe:` creates a separate overload the other modifiers apply to both versions as appropriate |
| `eval` + `unsafe` | ok: | `eval` and `unsafe` are orthogonal modifiers |
| `eval` + any other (except `unsafe`) | | `eval` implies compile-time evaluation incompatible with runtime modifiers |
| `async` + `const` | ok: | |
| `async` + `volatile` | ok: | |

---

## Visibility

| Keyword | Scope |
|---|---|
| `pub` | Accessible from any module |
| `priv` | Accessible only within the defining module (default) |
| `prot` | Accessible within the defining module and by subclasses in other modules |

```kairo
pub fn public_api()       { /* ... */ }
priv fn internal_helper() { /* ... */ }
prot fn for_subclasses()  { /* ... */ }
```

Visibility applies to both free functions and methods. See [Modules](/docs/language/modules) for how
visibility interacts with imports.

---

## ABI and Linkage

ABI modifiers control name mangling, dispatch mechanism, and symbol visibility at the object code level.

| Modifier | Description |
|---|---|
| `ffi "c"` | C linkage no name mangling. See [C/C++ Interop](/docs/language/c-c++) |
| `ffi "c++"` | C++ linkage Itanium or MSVC mangling. See [C/C++ Interop](/docs/language/c-c++) |
| `static` | Internal linkage; no vtable dispatch. Cannot be `virtual` or `override` |
| `virtual` | Dynamic dispatch via vtable. See [Classes](/docs/language/classes) |
| `override` | Overrides a `virtual` method from a base class; implies `virtual` |

`static`, `virtual`, and `override` are mutually exclusive with each other. `ffi` can be combined with any
of them.

```kairo
class Shape {
    virtual fn area(self) const -> f64 { return 0.0 }
}

class Circle : Shape {
    var radius: f64

    override fn area(self) const -> f64 {
        return 3.14159 * self.radius * self.radius
    }
}

class Math {
    static fn sqrt(x: f64) -> f64 { /* ... */ }
}

Math::sqrt(16.0)   // called without an instance
```

---

## Function Pointers

Functions are first-class values. The type of a function pointer is `fn(ParamTypes) -> ReturnType`:

```kairo
fn add(a: i32, b: i32) -> i32 = a + b
fn sub(a: i32, b: i32) -> i32 = a - b

var op: fn(i32, i32) -> i32 = add
op(3, 4)   // 7

op = sub
op(10, 3)  // 7
```

Functions can be nested inner functions are scoped to the enclosing function:

```kairo
fn outer(x: i32) -> i32 {
    fn inner(y: i32) -> i32 = y * 2
    return inner(x) + 1
}
```

---

## Closures

Anonymous functions (lambdas) capture variables from the enclosing scope. Default capture is by copy; use
`|&|` for capture-by-reference or specify per-variable:

```kairo
var multiplier = 3
var scale = fn (x: i32) -> i32 { return x * multiplier }   // captures multiplier by copy

scale(10)   // 30
```

See [Closures](/docs/language/closures) for capture modes (`|&|`, `|a, &b|`), lifetime rules, and how
closures interact with [AMT](/docs/language/amt).

---

## Operator Functions

Operators are overloaded with the `fn op` syntax:

```kairo
class Vec2 {
    var x: f64
    var y: f64

    fn op +(self, other: Vec2) -> Vec2 {
        return Vec2 { x: self.x + other.x, y: self.y + other.y }
    }
}
```

See [Operators](/docs/language/operators#operator-overloading) for the full list of overloadable operators,
special operator syntax (`l++`/`r++`, `op as`, `op in`, `op delete`), and restrictions.

---

## Forward Declarations

Functions can be forward-declared signature without a body for mutual recursion or when the
implementation is provided elsewhere (e.g., in a separate translation unit or via [C/C++ interop](/docs/language/c-c++)):

```kairo
fn parse_expression(tokens: [Token]) -> Expr           // forward declaration
fn parse_statement(tokens: [Token]) -> Stmt            // forward declaration

fn parse_expression(tokens: [Token]) -> Expr {
    // can call parse_statement here
}

fn parse_statement(tokens: [Token]) -> Stmt {
    // can call parse_expression here
}
```

The signature of the forward declaration must exactly match the later definition parameter types, return
type, and all modifiers. A mismatch is a compile error.

> [!NOTE]
> Forward declarations also apply to classes, structs, enums, and static variables. See
> [Classes](/docs/language/classes) and [Structures](/docs/language/structures) for type forward declarations.

---

## Summary

```kairo
// Basic function
fn add(a: i32, b: i32) -> i32 = a + b

// Default parameters + named arguments
fn connect(host: string = "localhost", port: i32 = 8080) { /* ... */ }
connect(port: 9090)

// Generic with bounds
fn <T impl Printable> show(value: T) { std::println(value as string) }

// Variadic
fn <...T> log(...args: T) { /* ... */ }

// Overloaded
fn process(x: i32) -> i32 { /* ... */ }
fn process(x: string) -> string { /* ... */ }

// Unsafe overload
fn process(x: i32) unsafe -> i32 { /* ... */ }

// Method with modifiers
class Server {
    pub fn start(self) async panic { /* ... */ }
    pub fn status(self) const -> string { /* ... */ }
    pub static fn default_port() -> i32 = 8080
}

// Function pointer
var handler: fn(Request) -> Response = handle_request

// No-return
fn abort() -> ! { std::crash(1) }
```

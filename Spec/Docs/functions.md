# Functions

Functions in Kairo follow a consistent declaration syntax for both free functions and class methods. The full
grammar covers visibility, ABI linkage, generics, modifiers, bounds, and return types all optional except
the `fn` keyword, the name, and the parameter list.

## In this section

- [Default, Named, and Variadic Parameters](/docs/language/functions-parameters/)
- [Parameter Passing Modes](/docs/language/functions-parameter-modes/)
- [Function Overloading](/docs/language/functions-overloading/)
- [Generators](/docs/language/functions-generators/)
- [Function Declarations](/docs/language/functions-declarations/): modifiers, visibility, ABI and linkage, forward declarations

---

## Declaration Syntax

```kairo
fn name(param1: Type1, param2: Type2) -> ReturnType {
    // body
}
```

The full grammar:

```bnf
function_declaration ::= visibility? abi_mod? leading_mods? "fn" generics? identifier
                         "(" parameter_list? ")" function_mods? ("->" return_type)? constraint? body

visibility    ::= "pub" | "priv" | "prot"
abi_mod       ::= ("ffi" string_literal) | "static" | "virtual" | "override"
leading_mods  ::= ("inline" | "eval")*       ; same meaning as in function_mods
generics      ::= "<" generic_param_list ">"
function_mods ::= ("const" | "volatile" | "unsafe" | "eval" | "async" | "final" | "panic" | "inline")*
constraint    ::= "requires" expression
return_type   ::= type | "!"
body          ::= block | "=" expression | ε        ; ε = forward declaration
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

Default parameters, named arguments, and variadic functions are covered in [Default, Named, and Variadic Parameters](/docs/language/functions-parameters/).

Parameter passing modes are covered in [Parameter Passing Modes](/docs/language/functions-parameter-modes/#parameter-passing-modes).

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

### Arrays are not returned

A function cannot return a fixed array `[T; N]` by value. Return a vector `[T]`, or fill an [`@inout`
parameter](/docs/language/functions-parameter-modes/):

```kairo
fn make() -> [i32; 3] { ... }           // compile error: 'make' returns an array
fn make() -> [i32] { return [1, 2, 3] } // ok: the caller owns a vector
fn make(@inout out: [i32; 3]) {         // ok: the caller owns the array
    out[0] = 1; out[1] = 2; out[2] = 3
}
```

Returning a slice literal is also an error, because the literal's storage ends with the function. See
[Primitives](/docs/language/collections/#how-long-a-slice-literals-storage-lives).

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

`!` is the **[no-return type](/docs/language/type-system/#the-never-type-)**. It is a subtype of every type, meaning it can appear anywhere a value is
expected:

```kairo
var x: i32 = if valid => compute() else => fatal("bad state")
// fatal() returns ! which coerces to i32
```

> [!WARNING]
> No-return functions cannot have a [`panic` specifier](/docs/language/panic/#the-panic-specifier). Since `panic` acts as an alternative return path, it
> contradicts the guarantee that the function never returns. The compiler rejects `fn f() panic -> !`.

Special return types and generators are covered in [Generators](/docs/language/functions-generators/).

---

## Expression-Bodied Functions

Single-expression functions can use the `=` shorthand, omitting braces and `return`:

```kairo
fn add(a: i32, b: i32) -> i32 = a + b
fn square(x: f64) -> f64 = x * x
fn greeting(name: string) -> string = f"Hello, {name}!"
```

The return type annotation is optional for expression-bodied functions it is
inferred from the expression when omitted. This is the only form of [return type
inference](/docs/language/type-system/#return-type-inference) in Kairo; block-bodied functions always require an explicit return type
(or default to `void`).

```kairo
fn add(a: i32, b: i32) = a + b              // inferred as i32
fn greeting(name: string) = f"Hi, {name}!"  // inferred as string
```

Explicit annotations are still useful when you want to constrain or widen the
inferred type:

```kairo
fn promote(x: i32) -> i64 = x as i64        // would otherwise infer i32
```

---

## Function Return

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

Function overloading is covered in [Function Overloading](/docs/language/functions-overloading/).

---

## Generic Functions

Generic functions declare [type parameters](/docs/language/generics/) in angle brackets before the function name:

```kairo
fn <T> identity(x: T) -> T {
    return x
}
```

Constrain type parameters with `impl` (interface conformance) or `derives` (class inheritance):

```kairo
fn <T impl Comparable> max(a: T, b: T) -> T {
    return if a > b => a else => b
}

fn <T derives Serializable> serialize(value: T) -> [byte] {
    return value.to_bytes()
}
```

> [!NOTE]
> `impl` checks structural conformance the type satisfies the interface's required method signatures
> without needing an explicit `impl` declaration. `derives` checks polymorphic inheritance the type is a
> subclass of the specified class. See [Interfaces](/docs/language/interfaces/) and
> [Requires Clauses](/docs/language/requires/) for details.

### Requires Clauses

For constraints beyond type parameter bounds, attach a `requires` clause after the return type:

```kairo
fn <T impl ToString> print_value(value: T) requires sizeof T <= 64 {
    std::println(value as string)
}
```

`requires` is a compile-time gate: the condition must hold at compile time or the program does not
compile. There is no runtime fallback and no dispatch. See [Requires Clauses](/docs/language/requires/) for the
full constraint system and [Where Clauses](/docs/language/where/) for runtime-conditional overload
dispatch.

---

Function modifiers, visibility, ABI and linkage, and forward declarations are covered in [Function Declarations](/docs/language/functions-declarations/).

---

## Function Pointers

Functions are first-class values. The type of a [function pointer](/docs/language/pointers/#function-pointers) is `fn(ParamTypes) -> ReturnType`:

```kairo
fn add(a: i32, b: i32) -> i32 = a + b
fn sub(a: i32, b: i32) -> i32 = a - b

var #op: fn(i32, i32) -> i32 = add
op(3, 4)   // 7

op = sub
op(10, 3)  // 7
```

Functions can be nested [inner functions](/docs/language/closures/#closures-vs-inner-functions) are scoped to the enclosing function:

```kairo
fn outer(x: i32) -> i32 {
    fn inner(y: i32) -> i32 = y * 2
    return inner(x) + 1
}
```

---

## Closures

Anonymous functions (lambdas) capture variables from the enclosing scope. Default capture is by copy; use
`|*|` to capture by pointer or specify per-variable:

```kairo
var multiplier = 3
var scale = fn (x: i32) -> i32 { return x * multiplier }   // captures multiplier by copy

scale(10)   // 30
```

See [Closures](/docs/language/closures/) for capture modes (`|*|`, `|a, *b|`), lifetime rules, and how
closures interact with [Tether](/docs/language/tether/).

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

See [Operators](/docs/language/operator-overloading/) for the full list of overloadable operators,
special operator syntax (`l++`/`r++`, `op as`, `op in`, `op delete`), and restrictions.

---

---

## Summary

```kairo
// Basic function
fn add(a: i32, b: i32) -> i32 = a + b

// Default parameters + named arguments
fn connect(host: string = "localhost", port: i32 = 8080) { /* ... */ }
connect(port: 9090)

// Parameter modes
fn append(@inout s: string, t: string) { s += t }
append(&name, "!")
fn sink(@move s: string) { /* ... */ }

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
    pub fn status(const self) -> string { /* ... */ }
    pub static fn default_port() -> i32 = 8080
}

// Function pointer
var handler: fn(Request) -> Response = handle_request

// No-return
fn abort() -> ! { std::crash(1) }
```

## See also

- [Default, Named, and Variadic Parameters](/docs/language/functions-parameters/)
- [Parameter Passing Modes](/docs/language/functions-parameter-modes/)
- [Function Overloading](/docs/language/functions-overloading/)
- [Generators](/docs/language/functions-generators/)
- [Function Declarations](/docs/language/functions-declarations/)
- [Closures](/docs/language/closures/)
- [Generics](/docs/language/generics/)
- [Operator Overloading](/docs/language/operator-overloading/)

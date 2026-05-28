# Macros

Macros in Kairo are token-level substitutions they operate on raw tokens before parsing, similar to
C/C++ `#define` but with scoping and balanced-delimiter requirements. Macros are identified by the `!`
suffix on their name.

For AST-level transformations with type awareness, see [Attributes](/docs/language/attributes).

---

## Defining Macros

A macro is defined with the `macro` keyword, a name ending in `!`, optional parameters, and a body.
The body must have balanced delimiters:

```kairo
macro double!(x) {
    x + x
}

macro greeting! {
    "hello, world"
}
```

At every use site, the preprocessor replaces the macro invocation with the body, substituting
parameters:

```kairo
var a = double!(5)     // replaced with: 5 + 5
var b = greeting!      // replaced with: "hello, world"
```

### Parameters

Parameters are typeless they accept any sequence of tokens. Multiple parameters are
comma-separated:

```kairo
macro clamp!(value, lo, hi) {
    if value < lo { lo } else if value > hi { hi } else { value }
}

var x = clamp!(temperature, 0, 100)
```

### Macros as arguments

Macros can be passed to other macros. The inner macro is expanded at the final substitution site:

```kairo
macro tag! { "debug" }
macro repeat!(m) { m! m! m! }

var labels = repeat!(tag)   // becomes: "debug" "debug" "debug"
```

---

## Built-in Macros

Kairo provides a set of compiler-intrinsic macros for common tasks.

### Token manipulation

| Macro | Description |
|---|---|
| `concat!(a, b)` | Join tokens into a single token |
| `stringify!(a)` | Convert a token to a string literal |
| `unstringify!(s)` | Convert a string literal back to tokens |

```kairo
var name = concat!(my, _var)       // becomes: my_var
var s = stringify!(some_ident)     // becomes: "some_ident"
```

> [!WARNING]
> `unstringify!` converts a string into raw tokens that are injected into the source. This is a
> potential injection risk only use with trusted, compile-time-known strings.

### Variadic helpers

| Macro | Description |
|---|---|
| `count!(...args)` | Number of arguments |
| `first!(...args)` | First argument |
| `last!(...args)` | Last argument |
| `rest!(...args)` | All arguments except the first |
| `init!(...args)` | All arguments except the last |

```kairo
count!(a, b, c)     // 3
first!(a, b, c)     // a
last!(a, b, c)      // c
rest!(a, b, c)      // b, c
init!(a, b, c)      // a, b
```

### Source location

| Macro | Description |
|---|---|
| `file!` | Current file path as a string literal |
| `line!` | Current line number as an integer literal |
| `column!` | Current column number as an integer literal |
| `module_path!` | Current module path as a string literal |

```kairo
std::println(f"logged from {file!}:{line!}")
```

### Diagnostics

| Macro | Description |
|---|---|
| `error!(msg)` | Emit a compile error with the given message |
| `warning!(msg)` | Emit a compile warning |
| `note!(msg)` | Emit a compile note |

```kairo
eval if platform == "wasm" {
    error!("WebAssembly is not supported yet")
}
```

An optional error code can be passed as a second argument:

```kairo
warning!("deprecated API", "W0042")
```

### Code generation

| Macro | Description |
|---|---|
| `include!(path)` | Paste file contents as tokens |
| `include_str!(path)` | File contents as a string literal |
| `embed!(path)` | File contents as a byte array (`[byte]`) |
| `unique_id!` | Generate a unique identifier |
| `todo!(msg)` | Runtime panic placeholder with optional message |
| `unreachable!(msg)` | Assert a code path is unreachable |

```kairo
// Embed a shader as a string
eval VERTEX_SHADER = include_str!("shaders/vertex.glsl")

// Embed a binary resource
eval ICON_DATA = embed!("assets/icon.png")

// Mark unfinished code
fn process() -> Config {
    todo!("implement config parsing")
}
```

`todo!()` panics at runtime with the given message. `unreachable!()` is undefined behavior if
reached the optimizer assumes the code path is dead.

### Conditional

| Macro | Description |
|---|---|
| `defined!(name)` | Check if a macro with the given name exists |

```kairo
eval if defined!(DEBUG_MODE) {
    fn log(msg: string) { std::println(f"[DEBUG] {msg}") }
} else {
    fn log(msg: string) { }
}
```

### Hygiene

| Macro | Description |
|---|---|
| `undef!(name)` | Remove a macro definition |

```kairo
macro TEMP! { 42 }
var x = TEMP!        // 42
undef!(TEMP)
// var y = TEMP!     // compile error: TEMP is not defined
```

---

## Compiler Intrinsic Macros

Some macros are compiler intrinsics that perform operations beyond token substitution:

| Macro | Description | Details |
|---|---|---|
| `label!(name)` | Declare a jump target | [Control Flow](/docs/language/control-flow#jumps) |
| `jump!(name)` | Unconditional jump to a label | [Control Flow](/docs/language/control-flow#jumps) |
| `forget!(ptr)` | Drop a pointer from AMT tracking | [Unsafe](/docs/language/unsafe#forget) |
| `unwrap!(expr)` | Force-unwrap a nullable, panic on null | [Variables](/docs/language/variables#force-unwrap) |
| `mref!(T)` | Produce an rvalue reference type (`&&T`) | [Classes](/docs/language/classes#the-rule-of-five) |

These use macro syntax (`name!`) to make their usage explicit and searchable in a codebase, but
they are not user-definable they are built into the compiler.

---

## Scoping

Unlike C/C++ `#define`, Kairo macros respect scope. A macro defined inside a module or block is
only visible within that scope:

```kairo
module internal {
    macro BUFFER_SIZE! { 4096 }
    var buf: [u8; BUFFER_SIZE!]
}

// BUFFER_SIZE! is not visible here
```

Top-level macros follow the same visibility rules as other declarations:

```kairo
pub macro MAX_RETRIES! { 3 }          // visible to importers
priv macro INTERNAL_FLAG! { true }     // file-scoped
```

---

## Macros vs Attributes

| | Macros | Attributes |
|---|---|---|
| Operates on | Raw tokens | AST nodes |
| Type awareness | No | Yes |
| Expansion time | Before parsing | After parsing |
| Can modify structure | Token substitution only | Can transform the AST |
| Syntax | `name!(args)` | `@name` on declarations |
| Hygiene | Scoped, balanced delimiters | Full AST hygiene |

Use macros for simple substitutions, constants, and conditional compilation. Use attributes for
code transformations that need type information or structural awareness.

See [Attributes](/docs/language/attributes) for the AST-level transformation system.

---

## Summary

```kairo
// Define a macro
macro square!(x) { x * x }
var s = square!(5)   // 25

// No-parameter macro
macro VERSION! { "1.0.0" }
std::println(f"version: {VERSION!}")

// Built-in macros
std::println(f"file: {file!}, line: {line!}")
eval SHADER = include_str!("shader.glsl")
eval ICON = embed!("icon.png")

// Variadic helpers
var n = count!(a, b, c, d)   // 4

// Diagnostics
eval if sizeof(usize) < 8 {
    error!("64-bit platform required")
}

// Conditional compilation
macro DEBUG! { true }
eval if defined!(DEBUG) {
    fn trace(msg: string) { std::println(f"[TRACE] {msg}") }
}

// Scoped macros
module config {
    priv macro DEFAULT_PORT! { 8080 }
    pub eval PORT = DEFAULT_PORT!
}
```
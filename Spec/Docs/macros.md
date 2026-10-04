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

#### Default values

A parameter may declare a default token run with `=`. When the caller omits the argument, the
default tokens substitute instead. Defaulted parameters must come after required ones:

```kairo
macro log!(msg, level = "info") {
    std::println(f"[{level}] {msg}")
}

log!("started")            // level defaults to "info"
log!("failed", "error")
```

#### Ignoring extra arguments

A bare `...` (no name) as the last parameter accepts any number of extra arguments and discards
them. Useful for macros that mirror a wider signature:

```kairo
macro trace!(msg, ...) { std::println(msg) }

trace!("hit", state, depth)   // state, depth are consumed and dropped
```

A `...` parameter (named or bare) must be last, and cannot follow defaulted parameters.

### Variadic macros and pack expansion

The `...` prefix on the last parameter declares a token pack: it captures any number of
comma-separated arguments. Inside the body, the pack expands with a **postfix** `...` — the same
declaration-prefix / expansion-postfix split used by variadic functions and pack expansion
expressions:

```kairo
macro list!(...xs) { [ xs... ] }

list!()          // [ ]
list!(1)         // [ 1 ]
list!(1, 2, 3)   // [ 1, 2, 3 ]
```

A bare splat `xs...` emits the pack's elements joined by commas. An empty pack consumes the splat
and emits nothing.

#### Pattern expansion

A parenthesized token run followed by `...` replicates the whole pattern once per pack element,
substituting the pack name with that element each time. Instances are comma-joined:

```kairo
macro wrap_all!(...xs) { [ (box(xs))... ] }

wrap_all!(1, 2, 3)   // [ box(1), box(2), box(3) ]
```

Ordinary parameters substitute inside patterns as usual:

```kairo
macro call_each!(f, ...xs) { (f(xs))... }

call_each!(log, a, b)   // log(a), log(b)
```

The outer parentheses are grouping syntax and are not emitted. To emit parentheses around each
instance, double them:

```kairo
macro pairs!(k, ...xs) { [ ((k, xs))... ] }

pairs!(id, 7, 8)   // [ (id, 7), (id, 8) ]
```

Two rules keep macro expansion from colliding with expression-level pack expansion in the output:
a postfix `...` after an identifier that is not the macro's pack, or after a parenthesized run
that never mentions the pack, passes through verbatim as target-language code. Expansion is
single-level — a nested `...` inside a pattern is emitted verbatim.

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

Builtin names are reserved: defining a macro with a builtin's name (`macro first!(...)`,
`macro paste!(...)`) is a compile error. Qualified macros (`mymod::first!`) do not collide —
builtins only claim the unqualified names.

### Token manipulation

| Macro | Description |
|---|---|
| `paste!(a, b)` | Paste identifier tokens into a single identifier |
| `stringify!(a)` | Convert a token to a string literal |
| `unstringify!(s)` | Convert a string literal back to tokens |

```kairo
var name = paste!(my, _var)        // becomes: my_var
var s = stringify!(some_ident)     // becomes: "some_ident"
```

`paste!` joins the spelling of every argument token and produces one identifier; the result must
be a valid identifier.

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
| `butlast!(...args)` | All arguments except the last |

```kairo
count!(a, b, c)     // 3
first!(a, b, c)     // a
last!(a, b, c)      // c
rest!(a, b, c)      // b, c
butlast!(a, b, c)   // a, b
```

These builtins expand macro invocations in their arguments first, then split on top-level commas,
so they compose:

```kairo
count!(rest!(a, b, c))   // 2
first!(rest!(a, b, c))   // b
```

`stringify!` and `defined!` are the exceptions: they operate on their arguments' raw tokens
(quoting and name-probing would be destroyed by expansion).

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
| `compile_error!(msg)` | Emit a compile error with the given message |
| `compile_warn!(msg)` | Emit a compile warning |
| `compile_note!(msg)` | Emit a compile note |

```kairo
eval if platform == "wasm" {
    compile_error!("WebAssembly is not supported yet")
}
```

The `compile_` prefix keeps these distinct from runtime logging: `compile_error!` aborts the
build, it does not log.

### Code generation

| Macro | Description |
|---|---|
| `include!(path)` | Paste file contents as tokens |
| `embed_str!(path)` | File contents as a string literal |
| `embed!(path)` | File contents as a byte array (`[byte]`) |
| `unique_id!` / `unique_id!(tag)` | Generate a unique identifier |
| `todo!(msg)` | Runtime panic placeholder with optional message |
| `unreachable!(msg)` | Assert a code path is unreachable (panics if reached) |
| `unreachable_unchecked!` | Optimizer hint: path is dead (UB if reached) |

```kairo
// Embed a shader as a string
eval VERTEX_SHADER = embed_str!("shaders/vertex.glsl")

// Embed a binary resource
eval ICON_DATA = embed!("assets/icon.png")

// Mark unfinished code
fn process() -> Config {
    todo!("implement config parsing")
}
```

`todo!()` and `unreachable!()` are SAFE: both panic at runtime if reached, with `unreachable!()`
signaling a logic error rather than missing code. `unreachable_unchecked!()` is the unsafe
variant: it is a hard assertion to the optimizer that the path is dead, and reaching it at
runtime is undefined behavior. Reach for `unreachable_unchecked!` only when the panic branch of
`unreachable!` shows up in a profile.

Untagged, `unique_id!` produces a fresh identifier on every invocation. The tagged form
`unique_id!(tag)` is stable within one dynamic macro expansion: every `unique_id!(guard)` inside
the same expansion instance yields the SAME identifier, letting a macro body refer to one
generated name in several places, while separate invocations of the macro still get distinct
names.

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

---

## Compiler Intrinsic Macros

Some macros are compiler intrinsics that perform operations beyond token substitution:

| Macro | Description | Details |
|---|---|---|
| `label!(name)` | Declare a jump target | [Control Flow](/docs/language/control-flow#jumps) |
| `jump!(name)` | Unconditional jump to a label | [Control Flow](/docs/language/control-flow#jumps) |
| `forget!(ptr)` | Drop a pointer from Tether tracking | [Unsafe](/docs/language/unsafe#forget) |
| `unwrap!(expr)` | Force-unwrap a nullable, panic on null | [Variables](/docs/language/variables#force-unwrap) |
| `mref!(T)` | Produce an rvalue reference type (`&&T`) | [Library](/docs/library/core/functions/move_refrence) |

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
eval SHADER = embed_str!("shader.glsl")
eval ICON = embed!("icon.png")

// Variadic helpers
var n = count!(a, b, c, d)   // 4

// Diagnostics
eval if sizeof usize < 8 {
    compile_error!("64-bit platform required")
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
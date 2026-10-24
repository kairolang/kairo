# Macros

Macros in Kairo are token-level substitutions they operate on raw tokens before parsing, similar to C/C++ `#define` but with scoping and balanced-delimiter requirements. Macros are identified by the `!` suffix on their name.

For AST-level transformations with type awareness, see [Attributes](/docs/language/attributes/).

## In this section

- [Built-in Macros](/docs/language/macros-builtin/)

---

## Defining Macros

A macro is defined with the `macro` keyword, a name ending in `!`, optional parameters, and a body. The body must have balanced delimiters:

```kairo
macro double!(x) {
    x + x
}

macro greeting! {
    "hello, world"
}
```

At every use site, the preprocessor replaces the macro invocation with the body, substituting parameters:

```kairo
var a = double!(5)     // replaced with: 5 + 5
var b = greeting!      // replaced with: "hello, world"
```

### Parameters

Parameters are typeless they accept any sequence of tokens. Multiple parameters are comma-separated:

```kairo
macro clamp!(value, lo, hi) {
    if value < lo => lo else if value > hi => hi else => value
}

var x = clamp!(temperature, 0, 100)
```

#### Default values

A parameter may declare a default token run with `=`. When the caller omits the argument, the default tokens substitute instead. Defaulted parameters must come after required ones:

```kairo
macro log!(msg, level = "info") {
    std::println(f"[{level}] {msg}")
}

log!("started")            // level defaults to "info"
log!("failed", "error")
```

#### Ignoring extra arguments

A bare `...` (no name) as the last parameter accepts any number of extra arguments and discards them. Useful for macros that mirror a wider signature:

```kairo
macro trace!(msg, ...) { std::println(msg) }

trace!("hit", state, depth)   // state, depth are consumed and dropped
```

A `...` parameter (named or bare) must be last, and cannot follow defaulted parameters.

### Variadic macros and pack expansion

The `...` prefix on the last parameter declares a token pack: it captures any number of comma-separated arguments. Inside the body, the pack expands with a **postfix** `...`. This is the same declaration-prefix / expansion-postfix split used by [variadic functions](/docs/language/functions-parameters/#variadic-functions) and [pack expansion](/docs/language/functions-parameters/#pack-expansion-and-forwarding) expressions:

```kairo
macro list!(...xs) { [ xs... ] }

list!()          // [ ]
list!(1)         // [ 1 ]
list!(1, 2, 3)   // [ 1, 2, 3 ]
```

A bare splat `xs...` emits the pack's elements joined by commas. An empty pack consumes the splat and emits nothing.

#### Pattern expansion

A parenthesized token run followed by `...` replicates the whole pattern once per pack element, substituting the pack name with that element each time. Instances are comma-joined:

```kairo
macro wrap_all!(...xs) { [ (box(xs))... ] }

wrap_all!(1, 2, 3)   // [ box(1), box(2), box(3) ]
```

Ordinary parameters substitute inside patterns as usual:

```kairo
macro call_each!(f, ...xs) { (f(xs))... }

call_each!(log, a, b)   // log(a), log(b)
```

The outer parentheses are grouping syntax and are not emitted. To emit parentheses around each instance, double them:

```kairo
macro pairs!(k, ...xs) { [ ((k, xs))... ] }

pairs!(id, 7, 8)   // [ (id, 7), (id, 8) ]
```

Two rules keep macro expansion from colliding with expression-level pack expansion in the output: a postfix `...` after an identifier that is not the macro's pack, or after a parenthesized run that never mentions the pack, passes through verbatim as target-language code. Expansion is single-level: a nested `...` inside a pattern is emitted verbatim.

### Macros as arguments

Macros can be passed to other macros. The inner macro is expanded at the final substitution site:

```kairo
macro tag! { "debug" }
macro repeat!(m) { m! m! m! }

var labels = repeat!(tag)   // becomes: "debug" "debug" "debug"
```

---

Built-in macros are covered in [Built-in Macros](/docs/language/macros-builtin/).

---

## Scoping

Unlike C/C++ `#define`, Kairo macros respect scope. A macro defined inside a [module](/docs/language/modules/) or block is only visible within that scope:

```kairo
module internal {
    macro BUFFER_SIZE! { 4096 }
    var buf: [u8; BUFFER_SIZE!]
}

// BUFFER_SIZE! is not visible here
```

Top-level macros follow the same [visibility rules](/docs/language/modules/#visibility-on-top-level-declarations) as other declarations:

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

Use macros for simple substitutions, constants, and [conditional compilation](/docs/language/macros-builtin/#conditional). Use attributes for code transformations that need type information or structural awareness.

See [Attributes](/docs/language/attributes/) for the AST-level transformation system.

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

---

## See also

- [Built-in Macros](/docs/language/macros-builtin/)
- [Attributes](/docs/language/attributes/)
- [Eval](/docs/language/eval/)
- [Modules](/docs/language/modules/)
- [Functions](/docs/language/functions/)
- [Variadic Functions](/docs/language/functions-parameters/#variadic-functions)

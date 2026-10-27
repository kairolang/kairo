# Built-in Macros

Kairo provides a set of compiler-intrinsic macros for common tasks.

Builtin names are reserved: defining a macro with a builtin's name (`macro first!(...)`, `macro paste!(...)`) is a compile error. Qualified macros (`mymod::first!`) do not collide; builtins only claim the unqualified names.

## Token manipulation

| Macro | Description |
|---|---|
| `paste!(a, b)` | Paste identifier tokens into a single identifier |
| `stringify!(a)` | Convert a token to a string literal |
| `unstringify!(s)` | Convert a string literal back to tokens |

```kairo
var name = paste!(my, _var)        // becomes: my_var
var s = stringify!(some_ident)     // becomes: "some_ident"
```

`paste!` joins the spelling of every argument token and produces one identifier; the result must be a valid identifier.

> [!WARNING]
> `unstringify!` converts a string into raw tokens that are injected into the source. This is a potential injection risk only use with trusted, compile-time-known strings.

## Variadic helpers

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

These builtins expand macro invocations in their arguments first, then split on top-level commas, so they compose:

```kairo
count!(rest!(a, b, c))   // 2
first!(rest!(a, b, c))   // b
```

`stringify!` and `defined!` are the exceptions: they operate on their arguments' raw tokens (quoting and name-probing would be destroyed by expansion).

## Source location

| Macro | Description |
|---|---|
| `file!` | Current file path as a string literal |
| `line!` | Current line number as an integer literal |
| `column!` | Current column number as an integer literal |
| `module_path!` | Current module path as a string literal |

```kairo
std::println(f"logged from {file!}:{line!}")
```

## Diagnostics

| Macro | Description |
|---|---|
| `compile_error!(msg)` | Emit a compile error with the given message |
| `compile_warn!(msg)` | Emit a compile warning |
| `compile_note!(msg)` | Emit a compile note |

```kairo
eval if defined!(__wasm__) {
    compile_error!("WebAssembly is not supported yet")
}
```

The `compile_` prefix keeps these distinct from runtime logging: `compile_error!` aborts the build, it does not log.

## Code generation

| Macro | Description |
|---|---|
| `include!(path)` | Paste file contents as tokens |
| `embed_str!(path)` | File contents as a string literal |
| `embed!(path)` | File contents as a byte array (`[byte]`) |
| `unique_id!` / `unique_id!(tag)` | Generate a unique identifier |
| `todo!(msg)` | Placeholder that crashes at runtime, with an optional message |
| `unreachable!(msg)` | Assert a code path is unreachable (crashes if reached) |
| `unreachable_unchecked!` | Optimizer hint: path is dead (UB if reached) |
| `crash!()` / `crash!(msg)` | End the process: write `msg` (if given) and a newline to stderr, then abort. Never returns |

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

`todo!()` and `unreachable!()` are SAFE: both crash at runtime if reached, like [`crash!()`](/docs/language/panic/#main-and-crash) (neither is a [panic](/docs/language/panic/): they join no panic set, so `fn process() -> Config { todo!(...) }` needs no `panic` specifier), with `unreachable!()` signaling a logic error rather than missing code. `unreachable_unchecked!()` is the unsafe variant: it is a hard assertion to the optimizer that the path is dead, and reaching it at runtime is undefined behavior. Reach for `unreachable_unchecked!` only when the crash branch of `unreachable!` shows up in a profile.

`crash!` is not a compiler intrinsic: it is an ordinary `pub macro` declared in the builtin library, and every file sees it without an import, the way it sees the builtin types. It expands to a call to a function that returns [`!`](/docs/language/panic/#panic-and-no-return-), so the compiler knows nothing after it runs: a function returning `T` may end in `crash!()` with no `return` after it. Like `todo!()`, it is not a [panic](/docs/language/panic/): it joins no panic set and no `try` catches it, and `main` may call it. Because it is a library macro rather than a reserved name, a macro named `crash!` that a file declares or imports itself takes precedence.

What a crash may do is deliberately small, because it runs on a program that has just proved itself wrong (its stack or heap may be damaged). It behaves like a signal handler: it writes the message and a newline to stderr in a single `write`, then aborts, and does nothing else. It never allocates, takes no lock, and runs no Kairo code, so `msg` is not formatted at crash time. A literal costs nothing; a runtime `string` is fine too, but only its bytes are written, as they are, and at most 4096 of them. A crash during a crash ends the process at once. Any `SIGABRT` handler the program installed is reset before the abort, so the process always dies of `SIGABRT` (exit status 134 from a shell). `unwrap!` on null, a failed checked `as` into a closed enum, and a failed [asserting downcast](/docs/language/casting/#downcasting-base-to-derived) end the program the same way, with a message the compiler writes (the expression, and its `file:line:col`).

Untagged, `unique_id!` produces a fresh identifier on every invocation. The tagged form `unique_id!(tag)` is stable within one dynamic macro expansion: every `unique_id!(guard)` inside the same expansion instance yields the SAME identifier, letting a macro body refer to one generated name in several places, while separate invocations of the macro still get distinct names.

## Conditional

| Macro | Description |
|---|---|
| `defined!(name)` | `true` if a macro with the given name exists, `false` otherwise |

```kairo
eval if defined!(DEBUG_MODE) {
    fn log(msg: string) { std::println(f"[DEBUG] {msg}") }
} else {
    fn log(msg: string) { }
}
```

`defined!` sees Kairo macros (a `macro NAME!` defined earlier, or `-D NAME` on the command line) and C/C++ macros: the target's predefined macros (`__linux__`, `_WIN32`, `__x86_64__`, `__aarch64__`, ...) and every macro the file's [`ffi`](/docs/language/c-cpp/) headers define. That makes it the way to select platform code:

```kairo
ffi "c" import "config.h"     // #define HAVE_FAST_PATH 1

eval if defined!(__linux__) && defined!(HAVE_FAST_PATH) {
    fn init() { /* ... */ }
} else {
    fn init() { /* fallback */ }
}
```

---

## Compiler Intrinsic Macros

Some macros are compiler intrinsics that perform operations beyond token substitution:

| Macro | Description | Details |
|---|---|---|
| `label!(name)` | Declare a jump target | [Control Flow](/docs/language/control-flow/#jumps) |
| `jump!(name)` | Unconditional jump to a label | [Control Flow](/docs/language/control-flow/#jumps) |
| `forget!(ptr)` | Drop a pointer from Tether tracking | [Unsafe](/docs/language/unsafe/#forget) |
| `unwrap!(expr)` | Force-unwrap a nullable; aborts the program on null | [Nullables](/docs/language/nullables/#force-unwrap) |
| `mref!(T)` | Produce an rvalue reference type (`&&T`) | [Library](/docs/library/core/functions/move_refrence/) |

These use macro syntax (`name!`) to make their usage explicit and searchable in a codebase, but they are not user-definable they are built into the compiler.

---

## See also

- [Macros](/docs/language/macros/)
- [Attributes](/docs/language/attributes/)
- [Eval](/docs/language/eval/#eval-if)
- [Diagnostics](/docs/language/diagnostics/)
- [Panic](/docs/language/panic/)

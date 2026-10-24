# Function Declarations

This page covers function modifiers, visibility, ABI and linkage, and forward declarations.

## Function Modifiers

Modifiers appear after the parameter list and before the return type arrow. Multiple modifiers can be combined, subject to the compatibility rules below. `inline` and `eval` may also be written before `fn` (`pub inline fn twice(x: i32) -> i32`); both positions mean the same thing.

```kairo
fn compute(x: i32) inline -> i32       { return x * x }
fn dangerous() unsafe -> void          { /* ... */ }
fn compile_time() eval -> i32          { return 42 }
fn may_fail() panic -> i32             { /* ... */ }
fn background() async -> Data          { /* ... */ }
```

### Modifier reference

| Modifier | Free functions | Methods | Description |
|---|---|---|---|
| `const` | | Yes | Method does not modify `self`. See [Variables](/docs/language/variables/#the-const-binding-rule) |
| `volatile` | Yes | Yes | Prevents certain compiler optimizations; for hardware interaction |
| `unsafe` | Yes | Yes | [Separate overload namespace](/docs/language/unsafe/#unsafe-function-overloads) for alternative implementations |
| `eval` | Yes | Yes | Must be evaluable at compile time. See [Eval](/docs/language/eval/) |
| `async` | Yes | Yes | Asynchronous execution. See [Concurrency](/docs/language/concurrency/) |
| `panic` | Yes | Yes | May panic; callers must handle. See [Panic](/docs/language/panic/) |
| `inline` | Yes | Yes | Puts the body in the interface. See [`inline`](#inline) |
| `final` | | Yes | Prevents override in subclasses. See [Classes](/docs/language/classes-inheritance/#final) |

### `inline`

`inline` puts the body in the interface: importers compile it themselves. Use it for small functions on hot paths, and for functions the C++ compiler calls on your behalf ([coroutine promises and awaiters](/docs/language/concurrency/#custom-awaitables)).

```kairo
pub inline fn twice(x: i32) -> i32 { return x * 2 }
```

Every module that can see the declaration gets the definition and compiles it, so the optimizer can inline the call there. In C++ terms it is an `inline` function: one shared definition that the linker merges across objects. It is not a request to force inlining.

- An `inline` function must have a body, in the same file as its declaration (an in-class declaration may be defined out of line in that file). An `inline` declaration with no body is an error.
- Every declaration of the function must agree on `inline`.
- Unused `inline` bodies cost parse time only: no code is generated for one nothing calls.

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

A top-level function with no visibility written is `pub`.

| Keyword | Scope of a top-level function |
|---|---|
| `pub` (default) | Any module that imports this module |
| `priv` | Current file only |
| `prot` | Current file and sibling files in the same library subtree |

```kairo
fn api()                  { /* ... */ }   // pub by default
priv fn internal_helper() { /* ... */ }
prot fn library_helper()  { /* ... */ }
```

See [Modules](/docs/language/modules/#visibility-on-top-level-declarations) for how visibility interacts with imports. Methods follow the member rules in [Classes](/docs/language/classes/#default-visibility).

---

## ABI and Linkage

ABI modifiers control name mangling, dispatch mechanism, and symbol visibility at the object code level.

| Modifier | Description |
|---|---|
| `ffi "c"` | C linkage no name mangling. See [C/C++ Interop](/docs/language/c-cpp/) |
| `ffi "c++"` | C++ linkage Itanium or MSVC mangling. See [C/C++ Interop](/docs/language/c-cpp/) |
| `static` | Internal linkage; no vtable dispatch. Cannot be `virtual` or `override` |
| `virtual` | Dynamic dispatch via vtable. See [Classes](/docs/language/classes-inheritance/#virtual-dispatch) |
| `override` | Overrides a `virtual` method from a [base class](/docs/language/classes-inheritance/#inheritance); implies `virtual` |

`static`, `virtual`, and `override` are mutually exclusive with each other. `ffi` can be combined with any of them.

```kairo
class Shape {
    virtual fn area(const self) -> f64 { return 0.0 }
}

class Circle derives Shape {
    var radius: f64

    override fn area(const self) -> f64 {
        return 3.14159 * self.radius * self.radius
    }
}

class Math {
    static fn sqrt(x: f64) -> f64 { /* ... */ }
}

Math::sqrt(16.0)   // called without an instance
```

---

## Forward Declarations

A function can be declared without a body a signature followed by no block:

```kairo
fn parse_expression(tokens: [Token]) -> Expr
fn parse_statement(tokens: [Token]) -> Stmt
```

Within a single module, forward declarations are rarely needed. Kairo hoists all top-level declarations before type checking, so mutual recursion works without them:

```kairo
fn is_even(n: u32) -> bool = if n == 0 => true else => is_odd(n - 1)
fn is_odd(n: u32) -> bool  = if n == 0 => false else => is_even(n - 1)
```

Forward declarations are used when the definition lives elsewhere:

- **FFI imports** the body is provided by a C or C++ library. See [C/C++ Interop](/docs/language/c-cpp/).
- **Separate translation units** the declaration is visible to callers; the definition is linked in from another `.k` file.
- **Out-of-line class methods** declared in the class body, defined outside it using the `Class::method` qualified-name syntax:

    ```kairo
    class Parser {
        var pos: usize
        fn advance(self)    -> Token
        fn peek(const self) -> Token
    }

    fn Parser::advance(self) -> Token {
        var t = self.tokens[self.pos]
        self.pos += 1
        return t
    }

    fn Parser::peek(const self) -> Token = self.tokens[self.pos]
    ```

    See [Classes](/docs/language/classes-out-of-line/#forward-declarations-and-out-of-line-definitions) for the full rules.

### Signature matching

When a definition follows a forward declaration, the two must match exactly:

- Parameter types, return type, and all function modifiers (`const`, `unsafe`, `panic`, `eval`, `async`, `inline`, `final`, `volatile`)
- Visibility (`pub`, `priv`, `prot`)
- ABI linkage (`ffi "c"`, `ffi "c++"`, `static`, `virtual`, `override`)

Parameter names may differ; the definition's names are used in the body. Defaults are not part of the match: each parameter's default may be written on any one declaration, and it applies to every call (see [Defaults apply to the whole function](/docs/language/functions-parameters/#defaults-apply-to-the-whole-function)).

A mismatch in any other element is a compile error.

## See also

- [Functions](/docs/language/functions/)
- [Default, Named, and Variadic Parameters](/docs/language/functions-parameters/)
- [Parameter Passing Modes](/docs/language/functions-parameter-modes/)
- [Function Overloading](/docs/language/functions-overloading/)
- [Generators](/docs/language/functions-generators/)
- [Modules](/docs/language/modules/)
- [Classes](/docs/language/classes/)
- [C/C++ Interop](/docs/language/c-cpp/)
- [Eval](/docs/language/eval/)
- [Panic](/docs/language/panic/)

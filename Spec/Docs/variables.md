# Variables & Bindings

| Keyword | Mutable | Storage | Initializer | Type annotation |
|---|---|---|---|---|
| `var` | Yes | Automatic | Optional (default-initialized) | Optional (inferred) |
| `const` | No | Automatic | Required | Optional (inferred) |
| `static` | Yes | Static | Optional | Required |
| `eval` | No | Compile-time | Required | Optional (inferred) |

> Variables in Kairo are mutable by default. `const` bindings at local scope require an initializer, but
> class-level `const` members can be left uninitialized at declaration and assigned exactly once in the
> constructor body. See [Classes](/docs/language/classes#const-members-in-constructors) for details.

```kairo
var x = 42
var y: string = "Hello, World!"
```

Multi-variable declarations on a single line are not supported. Each binding gets its own statement.

---

## Naming Conventions

Kairo recommends the following conventions. They are not enforced as hard errors, but the compiler emits
readability warnings when they are not followed.

| Kind | Convention | Example |
|---|---|---|
| Variables | snake_case | `my_value` |
| Functions | snake_case | `get_name` |
| Constants | UPPER_SNAKE_CASE | `MAX_SIZE` |
| Types (classes, structs, enums) | PascalCase | `HttpServer` |

---

## Type Inference

The compiler infers the type from the initializer when no annotation is provided. Explicit annotations are
optional but can be used to force a specific type.

```kairo
var a = 42          // inferred as i32
var b = 3.14        // inferred as f64
var c: u8 = 42      // explicitly u8
var d = "hello"     // inferred as string
```

See [Primitives](/docs/language/primitives) for default type rules integer literals default to `i32`, float
literals default to `f64`.

---

## Declaration Shorthands

When the type is fully determined by the initializer, the `*` or `unsafe *` qualifier can be placed on the
variable name instead of writing out the full type annotation:

```kairo
var *ptr = std::create<i32>(10)
// equivalent to: var ptr: *i32 = std::create<i32>(10)

var unsafe *raw = unsafe std::alloc<i32>(sizeof i32 * 1)
// equivalent to: var raw: unsafe *i32 = unsafe std::alloc<i32>(sizeof i32 * 1)
```

The nullable shorthand `?` works the same way:

```kairo
var name? = get_name()
// equivalent to: var name: string? = get_name()
```

These are purely syntactic sugar the compiler infers the full type from the right-hand side. The long
form is always valid and preferred when clarity matters.

---

## Default Initialization

All types with a default constructor are zero-initialized when declared without an initializer. Integers default
to `0`, booleans to `false`, strings to `""`, collections to empty.

```kairo
var a: i32        // 0
var b: string     // ""
var c: bool       // false
var d: [i32]      // []
```

If a type has its default constructor explicitly deleted, declaring a variable without an initializer produces
a compiler warning for uninitialized state.

```kairo
class Token {
    fn Token() = delete
}

var t: Token   // ⚠ warning: t is uninitialized (suppress with @no_warn(UNINIT))
```

---

## Constants

Immutable bindings use `const`. A `const` variable cannot be reassigned after initialization.

```kairo
const x = 42
const name: string = "Kairo"
// x = 100  // compile error: x is const
```

Unlike `var`, a `const` binding without an initializer is a hard compile error constants must always be
explicitly initialized.

```kairo
const x: i32       // compile error: const requires an initializer
```

---

## Compile-Time Constants (`eval`)

For values that must be resolved at compile time, use `eval`. This is equivalent to C++'s `consteval` the
expression **must** be evaluable at compile time, and a compile error is raised if it cannot be.

```kairo
eval PI = 3.14159
eval MAX_SIZE = 1024 * 1024
```

`eval` bindings are implicitly `const`. See [Eval](/docs/language/eval) for full details on compile-time
evaluation, including `eval` functions and restrictions.

---

## Static Variables

`static` declares a binding with static storage duration it lives for the entire program. Unlike `var`,
`static` requires an explicit type annotation.

```kairo
static counter: i32 = 0
```

`static` can be combined with `const` for immutable static data. See [Modules](/docs/language/modules) for
`static` at module scope.

---

## Shadowing

Constants can shadow previous bindings of the same name. Each `const` declaration creates a new binding the
previous one becomes inaccessible.

```kairo
const raw = "42"
const raw = std::parse<i32>(raw)   // shadows string with i32 valid
const raw = raw * 2                // shadows again valid
```

Mutable variables cannot shadow. Redeclaring a `var` with the same name in the same scope is a compile error.

```kairo
var x = 42
var x = 100   // compile error: var cannot shadow
```

> [!NOTE]
> Shadowing is restricted to `const` because shadowing a mutable variable is almost always a bug you likely
> meant to reassign (`x = 100`) rather than redeclare.

---

## Destructuring

Tuples and structs can be destructured into individual bindings. Use parentheses for tuples and curly braces
for structs.

### Tuples

```kairo
var point = (10, 20, 30)
var (x, y, z) = point
// x = 10, y = 20, z = 30
```

### Structs

```kairo
struct Color {
    var r: u8
    var g: u8
    var b: u8
}

var color = Color { r: 255, g: 128, b: 0 }
var {r, g, b} = color
// r = 255, g = 128, b = 0
```

Destructured names must match the field names in the struct definition. The binding order follows the
definition order.

### Discards

Use `_` to ignore values you don't need. `_` is not a variable it cannot be referenced after destructuring.

```kairo
var (x, _, z) = (1, 2, 3)     // discard the second element
var {r, _, _} = color         // keep only r

for _ in 0..10 {
    // loop body doesn't need the index
}
```

The compiler will error if you attempt to use `_` as a value.

---

## Nullable Types

`T?` is sugar for `Nullable<T>` a compiler-intrinsic tagged union that holds either a value of type `T`
or null. It applies to any type, not just pointers.

```kairo
var name: string? = get_name()   // may be null
var count: i32? = null           // explicitly null
```

### Shorthand declaration

The `?` suffix on the variable name infers the nullable type from the initializer:

```kairo
var name? = get_name()           // inferred as string?
// var x? = null                 // compile error: no underlying type to infer
```

### Null checking

The `?` suffix on a variable name in a condition checks for non-null:

```kairo
var result? = find_user("alice")

if result? {
    // result is non-null here
    std::println(result.name)
}
```

Accessing members on an unchecked nullable is a compile error:

```kairo
var user? = find_user("alice")
user.name   // compile error: user has not been null-checked
```

### Safe access (`?.`)

The `?.` operator calls a method or accesses a member only if the value is non-null. If null, it
default-constructs the type and calls the method on that instead:

```kairo
var config? = load_config()
config?.timeout   // if null, uses Config().timeout
```

If the type is not trivially default-constructible (deleted default constructor, contains atomic types),
`?.` is a compile error.

### Null coalescing (`??`)

`??` provides a fallback value when the left side is null. Both sides must be the same underlying type:

```kairo
var value = get_f32() ?? 0.212   // value is f32, not f32?
var name = get_name() ?? "anonymous"
```

### Force unwrap

`unwrap!()` extracts the value or panics if null:

```kairo
var x = unwrap!(maybe_value)   // panics if null
```

`unwrap!()` desugars to a null check followed by a `panic` on the null path. The caller must be inside
a `try` block or in a function with the `panic` specifier. See [Panic](/docs/language/panic) for the
panic model.

### `const` interaction

`const` on a nullable binding works the same as on any other type the binding cannot be reassigned
after initialization:

```kairo
const x: i32? = 42
x = null   // compile error: x is const
x = 100    // compile error: x is const

var y: i32? = null
y = 42     // ok: var is mutable
y = null   // ok: can go back to null
```

### Pointers and nullability

`*T` is non-null by construction, it cannot hold `&null`. No null checks are needed on dereference
because the pointer is always valid:

```kairo
var x = 42
var ptr: *i32 = &x
*ptr = 10              // guaranteed valid, no check

var bad: *i32 = &null  // compile error: *T is non-null
```

To represent a pointer that might not exist, use `*T?`. This wraps the pointer in the standard
`Nullable<T>` system with full support for `?`, `?.`, `??`, and `unwrap!()`:

```kairo
var ptr: *i32? = find_pointer()

if ptr? {
    std::println(*ptr)          // compiler knows ptr is non-null here
}

var val = ptr ?? &fallback      // use fallback if null
var forced = unwrap!(ptr)       // panics if null
```

For raw nullable pointers with no compiler tracking, use `unsafe *T` with manual null comparison:

```kairo
var raw: unsafe *i32 = &null
if raw != &null {
    std::println(*raw)
}
```

See [Pointers](/docs/language/pointers) for the full pointer model and how
[AMT](/docs/language/amt) tracks pointer provenance.

---

## The `const` Binding Rule

`const` in Kairo follows a strict **left-to-right binding rule**: one `const` applies to the thing immediately
to its right. This eliminates the ambiguity that plagues C/C++ `const` placement.

### On simple variables

```kairo
const x: i32 = 42
//    ^ x cannot be reassigned
//       ^^^ i32 is the type immediately right of const the value is immutable
```

### On pointers

`const` on the binding and `const` on the pointed-to type are independent axes:

```kairo
var ptr: *i32 = &x
// ptr is mutable, *ptr is mutable can reassign ptr and modify the target

const ptr: *i32 = &x
// ptr is const cannot reassign ptr to point elsewhere
// *ptr is mutable can still modify the target value
*ptr = 10    // ok: allowed
ptr = &y     // compile error:

const ptr: *const i32 = &x
// ptr is const cannot reassign
// *ptr is const cannot modify the target
*ptr = 10    // compile error:
ptr = &y     // compile error:
```

The rule scales to any depth:

```kairo
const ptr: *const *i32 = &ptr2
ptr = &ptr3    // ptr is: const
*ptr = &x      // *ptr is: const
**ptr = 10     // ok: the i32 at the end is not const
```

### A practical example

Consider a configuration object that should be readable through a pointer but never modified:

```kairo
class Config {
    pub var host: string
    pub var port: i32

    fn Config(self, host: string, port: i32) {
        self.host = host
        self.port = port
    }

    fn address(const self) -> string {
        return f"{self.host}:{self.port}"
    }

    fn set_port(self, port: i32) {
        self.port = port
    }
}

var config = Config("localhost", 8080)

const ptr: *const Config = &config
ptr->address()       // ok: address() is a const method
ptr->set_port(9090)  // compile error: set_port() mutates, ptr points to const Config

// in most cases tho you would only want this:
var ptr: *const Config = &config
// cause you would have a const type but still be able to reassign the pointer if needed.
```

### On types

`const` applied to a type restricts the instance to const methods only methods not marked `const` cannot be
called.

```kairo
const server = Config("localhost", 8080)
server.address()       // ok: const method
server.set_port(9090)  // compile error: set_port() is not const
```

> [!WARNING]
> `var x: const i32 = 42` is a compile error. The `const` binding rule is strictly left-to-right from the
> declaration keyword position. Use `const x: i32 = 42` instead. This avoids the `const int* x` vs
> `int* const x` confusion that C++ is notorious for.

---

## Scope and Lifetime

Variables are block-scoped and destroyed at the end of their enclosing block.

```kairo
{
    var x = 42
    // x is live here
}
// x is no longer accessible
```

[AMT](/docs/language/amt) performs full-program analysis to track lifetimes automatically no lifetime
annotations are required. If AMT determines that a pointer outlives its referent and cannot automatically
promote the pointer (to a shared, weak, or unique smart pointer), it emits a compile error.

```kairo
var x = 10
var y = &x
{
    *y = 15    // ok: x is still alive, y is valid
}
std::println(*y)      // AMT error: y's safety cannot be guaranteed at this point
```

See [AMT](/docs/language/amt) and [Ownership](/docs/language/ownership) for the full lifetime and borrowing
model.

---

All four declaration keywords `var`, `const`, `static`, `eval` work in both local and class/struct scope.

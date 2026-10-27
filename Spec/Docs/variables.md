# Variables & Bindings

| Keyword | Mutable | Storage | Initializer | Type annotation |
|---|---|---|---|---|
| `var` | Yes | Automatic | Optional (default-initialized) | Optional (inferred) |
| `const` | No | Automatic | Required | Optional (inferred) |
| `static` | Yes | Static | Optional | Optional (inferred) |
| `thread` | Yes | Thread-local (one instance per thread) | Optional | Optional (inferred) |
| `eval` | No | Compile-time | Required | Optional (inferred) |

> Variables in Kairo are mutable by default. `const` bindings at local scope require an initializer, but class-level `const` members can be left uninitialized at declaration and assigned exactly once in the constructor body. See [Classes](/docs/language/classes/#const-members-in-constructors) for details.

```kairo
var x = 42
var y: string = "Hello, World!"
```

Multi-variable declarations on a single line are not supported. Each binding gets its own statement.

---

## Identifiers

An identifier is a run of letters, digits, `_`, `#` and any non-ASCII (UTF-8) characters, and it cannot begin with a digit. `#` has no special meaning: it is an ordinary name character, valid at the start, in the middle or at the end of a name, as many times as you like. There is no length limit.

```kairo
var count = 0
var größe = 12
var item#2 = "second"
var a#b##c__42 = true
```

Keywords are spelled only with ASCII letters, digits and `_`, so a name containing `#` (or any non-ASCII character) is never a keyword. That makes `#` a convenient way to use a keyword's spelling as a name: `#op`, `#match` and `#type` are plain identifiers. Each is its own name, distinct from the keyword and from any other spelling: `#op` and `op#` are two different variables, and you write the `#` every time you use one.

```kairo
var #type: string = "circle"
std::println(#type)
```

---

## Naming Conventions

Kairo recommends the following conventions. They are not enforced as hard errors, but the compiler emits readability warnings when they are not followed.

| Kind | Convention | Example |
|---|---|---|
| Variables | snake_case | `my_value` |
| Functions | snake_case | `get_name` |
| Constants | UPPER_SNAKE_CASE | `MAX_SIZE` |
| Types (classes, structs, enums) | PascalCase | `HttpServer` |

---

## Type Inference

The compiler infers the type from the initializer when no annotation is provided. Explicit annotations are optional but can be used to force a specific type.

```kairo
var a = 42          // inferred as i32
var b = 3.14        // inferred as f64
var c: u8 = 42      // explicitly u8
var d = "hello"     // inferred as string
```

See [Primitives](/docs/language/primitives/) for default type rules integer literals default to `i32`, float literals default to `f64`.

---

## Declaration Shorthands

When the type is fully determined by the initializer, the `*` or `unsafe *` qualifier can be placed on the variable name instead of writing out the full type annotation:

```kairo
var *ptr = @create i32(10)
// equivalent to: var ptr: *i32 = @create i32(10)

var unsafe *raw = unsafe std::alloc<i32>(sizeof i32 * 1)
// equivalent to: var raw: unsafe *i32 = unsafe std::alloc<i32>(sizeof i32 * 1)
```

The [nullable shorthand `?`](/docs/language/nullables/#shorthand-declaration) works the same way:

```kairo
var name? = get_name()
// equivalent to: var name: string? = get_name()
```

The stars give the pointer depth, to any depth, and they combine with `?`:

```kairo
var x = 5
var *p = &x            // *i32
var **pp = &p          // **i32
var ***ppp = &pp       // ***i32
var *n? = &x           // (*i32)?: a nullable pointer, wrapped once
var *m? = find_ptr()   // find_ptr() -> (*i32)?: m is (*i32)?, not ((*i32)?)?
```

These are purely syntactic sugar the compiler infers the full type from the right-hand side. The shorthand never converts anything: the stars must match the initializer, and a mismatch is a compile error whose fix-it writes the right spelling:

```kairo
var *bad = &p          // error: '*bad' states a pointer of depth 1, but its initializer is '**i32', a pointer of depth 2; write '**bad'
var *notp = x          // error: '*notp' declares a pointer, but its initializer has type 'i32', which is not one
var unsafe *s = &x     // error: 'unsafe *s' declares an unsafe pointer, but its initializer is the safe pointer '*i32'; write '*s'
var *m2 = find_ptr()   // error: '*m2' is initialized with a nullable '*i32?'; write '*m2?' so the declaration says it may be null
```

`unsafe` describes the outermost pointer only, as in the type `unsafe **i32` (an unsafe pointer to a safe `*i32`). A shorthand and a type annotation on the same name (`var *p: *i32`, `var x?: i32`) is an error: write one or the other. Fields declare their type and never take a shorthand.

The long form is always valid and preferred when clarity matters.

A binding with neither an annotation nor a shorthand whose inferred type is nullable or a pointer gets a warning, so the declaration always shows what the binding is. The fix-it writes the shorthand:

```kairo
var n = find()         // warning: 'n' is nullable; write 'n?' so it reads as one
var p = &x             // warning: 'p' is a pointer; write '*p'
var pp = &p            // warning: 'pp' is a pointer; write '**pp'
var r = raw()          // raw() -> unsafe *i32. warning: 'r' is a pointer; write 'unsafe *r'
var m = find_ptr()     // warning: 'm' is a nullable pointer; write '*m?' so it reads as one
var q: *i32 = &x       // no warning: the type is written
```

Destructuring and `for` bindings are not checked, and neither is a binding whose type depends on a generic parameter.

---

## Default Initialization

Types with a default value are zero-initialized when declared without an initializer. Integers default to `0`, strings to `""`, collections to empty.

```kairo
var a: i32        // 0
var b: string     // ""
var d: [i32]      // []
```

`bool` has no default value: declaring a `bool` without an initializer is an error. The same applies to a struct or class with no default constructor, including one whose default constructor is explicitly deleted, to an [enum with payloads](/docs/language/enums-adt/) (no variant is its default), and to an array of any of these. A class field of such a type is initialized by the constructor instead; see [Classes](/docs/language/classes/#fields-without-a-default).

```kairo
var c: bool       // error: c must be initialized

class Token {
    fn Token(self) = delete
}

var t: Token      // error: Token has no default constructor
```

---

## Constants

Immutable bindings use `const`. A `const` variable cannot be reassigned after initialization.

```kairo
const x = 42
const name: string = "Kairo"
// x = 100  // compile error: x is const
```

Unlike `var`, a `const` binding without an initializer is a hard compile error constants must always be explicitly initialized.

```kairo
const x: i32       // compile error: const requires an initializer
```

---

## Compile-Time Constants (`eval`)

For values that must be resolved at compile time, use `eval`. This is equivalent to C++'s `consteval` the expression **must** be evaluable at compile time, and a compile error is raised if it cannot be.

```kairo
eval PI = 3.14159
eval MAX_SIZE = 1024 * 1024
```

`eval` bindings are implicitly `const`. See [Eval](/docs/language/eval/) for full details on compile-time evaluation, including `eval` functions and restrictions.

---

## Static Variables

`static` declares a binding with static storage duration it lives for the entire program. Its type follows the same rule as `var`: write a type, an initializer, or both, and with an initializer the type is inferred. A `static` with neither is an error.

```kairo
static counter: i32 = 0
static limit = 64        // i32
static *top = &limit      // *i32
```

`static` can be combined with `const` for immutable static data, in either order: `static const` and `const static` are the same declaration. The `const` applies to the binding itself, so the static cannot be reassigned; a `const` deeper in the type (`static p: *const i32`) only protects what it points to. The shorthands work as usual.

```kairo
static const LIMIT = 64          // const i32, static storage
const static NAME: string = "k"  // same thing, other order
static const *ROOT = &limit      // *i32 that cannot be re-pointed
```

Seen from C++, a namespace-scope `static const` is a `const` variable, a function-local one is `static const`, and a class member is a `static const` data member. `eval` is already `const`, so `eval const` and `const eval` are accepted and mean exactly `eval`. See [Modules](/docs/language/modules/) for `static` at module scope.

---

## Thread-Local Variables

`thread` declares a binding with thread storage duration: every thread gets its own instance, initialized when the thread first touches it and destroyed when that thread exits. Like `static`, its type may be written or inferred from the initializer, and it may appear at file scope, class scope, or inside a function body. A function-local `thread` keeps its value across calls on the same thread, like a static local, and is independent per thread.

```kairo
thread counter: i32 = 0
thread const WORKER_NAME: string = "worker"

class Pool {
    thread current: *Pool?
}

fn next_id() -> u64 {
    thread counter: u64 = 0
    counter += 1
    return counter
}
```

`thread` combines with `const` the way `static` does. A `thread` binding without an initializer is default-initialized per thread under the rules in [Default Initialization](#default-initialization). Access is `name` at file scope and `Self::name` / `Type::name` at class scope, the same as `static`. Seen from C++, a `thread` binding is a `thread_local` variable (`static thread_local` in a class or a function body). `static thread` is accepted as another spelling of `thread`.

---

## Shadowing

Constants can shadow previous bindings of the same name. Each `const` declaration creates a new binding the previous one becomes inaccessible.

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
> Shadowing is restricted to `const` because shadowing a mutable variable is almost always a bug you likely meant to reassign (`x = 100`) rather than redeclare.

---

## Destructuring

[Tuples](/docs/language/collections/#tuples-t1-t2-) and [structs](/docs/language/structures/) can be destructured into individual bindings. Use parentheses for tuples and curly braces for structs.

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

Destructured names must match the field names in the struct definition. The binding order follows the definition order.

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

Nullable types are covered in [Nullables](/docs/language/nullables/).

---

## The `const` Binding Rule

Every `const` in Kairo answers one yes-or-no question about one thing: *can this be changed?*

A plain value is one thing, so it has one question. A pointer is two things, the pointer and the value it points at, so it has two:

1. **Can I change the pointer?** That is, can it be made to point somewhere else.
2. **Can I change the pointee?** That is, can the value it points at be written through it.

The two answers are independent, and each one is written in its own place:

| Question | Where it is written | Yes | No |
|---|---|---|---|
| Can I change the pointer? | The declaration keyword | `var ptr` | `const ptr` |
| Can I change the pointee? | Directly after the `*` | `*T` | `*const T` |

Those are the only places a `const` can go, and a `const` always applies to the thing immediately to its right. You read a declaration left to right and each `const` you meet answers one question. There is never a puzzle about which part of the type a `const` belongs to, the way there is with `const int*` and `int* const` in C and C++.

### On simple variables

A plain value has only the first question:

```kairo hints
const x: i32 = 42
x = 10    // compile error: x is const
```

### On pointers

Two questions with two answers each gives four combinations:

| Declaration | Change the pointer? | Change the pointee? |
|---|---|---|
| `var ptr: *i32` | Yes | Yes |
| `const ptr: *i32` | No | Yes |
| `var ptr: *const i32` | Yes | No |
| `const ptr: *const i32` | No | No |

```kairo hints
var a: *i32 = &x
a = &y       // ok
*a = 10      // ok

const b: *i32 = &x
b = &y       // compile error: b is const, it cannot point anywhere else
*b = 10      // ok: the pointee is still writable

var c: *const i32 = &x
c = &y       // ok: c can point somewhere else
*c = 10      // compile error: cannot write through a *const pointer

const d: *const i32 = &x
d = &y       // compile error
*d = 10      // compile error
```

> [!TIP]
> `var ptr: *const T` is the one you will reach for most: a read-only view of something that you can still re-point. Add `const` on the binding only when the pointer itself must never move.

The rule scales to any depth. Every `*` adds one more thing that can be pointed at, and so one more place a `const` can go:

```kairo hints
const ptr: *const *i32 = &ptr2
ptr = &ptr3    // compile error: ptr is const
*ptr = &x      // compile error: the inner pointer is const
**ptr = 10     // ok: the i32 at the end is not const
```

`*const T` answers "can I write through *this* pointer?". It does not answer "can anyone change this value?". Another pointer to the same value may still be writable. See [Ownership](/docs/language/ownership/#pointer-aliasing).

### A practical example

Consider a configuration object that should be readable through a pointer but never modified:

```kairo hints
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

var ptr: *const Config = &config
ptr->address()       // ok: address() is a const method
ptr->set_port(9090)  // compile error: set_port() mutates, ptr points to const Config
```

### On objects and methods

`const self` is the pointee question asked about the receiver: can this method change the object it is called on? A `const` object, or one reached through a `*const T`, only allows methods that answer no.

```kairo hints
const server = Config("localhost", 8080)
server.address()       // ok: const method
server.set_port(9090)  // compile error: set_port() is not const
```

> [!WARNING]
> `var x: const i32 = 42` is a compile error. A plain value has one question, and the declaration keyword already answers it, so write `const x: i32 = 42`. For the same reason `var ptr: const *const i32` is rejected: the pointer question belongs to the keyword, so write `const ptr: *const i32`. This avoids the `const int* x` vs `int* const x` confusion that C++ is notorious for.

---

## Scope and Lifetime

Variables are block-scoped and [destroyed at the end of their enclosing block](/docs/language/ownership/#destruction-order).

```kairo
{
    var x = 42
    // x is live here
}
// x is no longer accessible
```

[Tether](/docs/language/tether/) performs full-program analysis to track lifetimes automatically no lifetime annotations are required. If Tether determines that a pointer outlives its referent and cannot automatically [promote the pointer](/docs/language/tether-promotion/) (to a shared, weak, or unique smart pointer), it emits a compile error.

```kairo
var x = 10
var *y = &x
{
    *y = 15    // ok: x is still alive, y is valid
}
std::println(*y)      // Tether error: y's safety cannot be guaranteed at this point
```

See [Tether](/docs/language/tether/) and [Ownership](/docs/language/ownership/) for the full lifetime and borrowing model.

---

All five declaration keywords `var`, `const`, `static`, `eval`, `thread` work in both local and class/struct scope.

## See also

- [Nullables](/docs/language/nullables/)
- [Primitives](/docs/language/primitives/)
- [Eval](/docs/language/eval/)
- [Pointers](/docs/language/pointers/)
- [Ownership](/docs/language/ownership/)
- [Tether](/docs/language/tether/)
- [Collections](/docs/language/collections/)
- [Structures](/docs/language/structures/)

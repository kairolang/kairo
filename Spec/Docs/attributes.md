# Attributes

Attributes are compile-time AST transformations. They modify the structure of declarations renaming fields, injecting code, adding members with full access to the parsed syntax tree and type information. Unlike [macros](/docs/language/macros/), which operate on raw tokens before parsing, attributes run after parsing and can inspect and modify typed AST nodes.

| Property | Guarantee |
|---|---|
| Type safety | Yes |
| Hygiene | Yes |
| Scope | Yes |
| Expansion time | Compile time |
| Expansion order | Inner to outer |
| Expansion context | The node the attribute is attached to |

---

## Defining Attributes

> Attribute macros parse, but the compiler does not expand them yet: using one is rejected with [SC116E](/docs/language/diagnostics/#sc116e-a-feature-is-not-yet-supported) rather than doing nothing. See [Status](/docs/status/).

Attributes are defined with the `macro` keyword followed by `@name` and a parameter list. The first parameter is always a pointer to the AST node being transformed:

```kairo
import std::AST

macro @add_logging(node: *AST::FunctionDecl) {
    node->body.prepend(
        AST::parse!(std::println(f"entering {stringify!(node->name)}"))
    )
    node->body.append(
        AST::parse!(std::println(f"exiting {stringify!(node->name)}"))
    )
}
```

```kairo
@add_logging
fn process_data(x: i32) -> i32 {
    return x * 2
}
```

After expansion:

```kairo
fn process_data(x: i32) -> i32 {
    std::println("entering process_data")
    var __result = x * 2
    std::println("exiting process_data")
    return __result
}
```

### Node preservation rule

Attributes must preserve the node type. An attribute attached to a function declaration receives a `*AST::FunctionDecl` and must leave it as a function declaration it cannot replace it with a class or a variable. This ensures the expansion process is deterministic and the AST remains structurally consistent.

To add new nodes, create them with `@create AST::NodeType()` and attach them to the existing node (e.g., appending statements to a function body, adding members to a class).

---

## Attribute Arguments

Attributes can take additional arguments beyond the implicit node parameter:

```kairo
macro @repeat(block: *AST::Block, times: i32) {
    var original = block->clone()
    var *expanded = @create AST::Block()

    for i in 0..times {
        expanded->body.append(original.clone())
    }

    *block = *expanded
}

@repeat(3)
{
    std::println("hello")
}
```

After expansion:

```kairo
{
    { std::println("hello") }
    { std::println("hello") }
    { std::println("hello") }
}
```

Arguments are passed in parentheses after the attribute name at the use site. The node parameter is implicit it is always the declaration or block the attribute is attached to.

---

## Overloading

Attribute definitions can be overloaded by node type or argument types. The compiler selects the correct overload based on what the attribute is attached to:

```kairo
macro @serialize(node: *AST::ClassDecl) {
    // generate serialization for a class
}

macro @serialize(node: *AST::StructDecl) {
    // generate serialization for a struct
}
```

```kairo
@serialize
class Config { ... }    // calls the ClassDecl overload

@serialize
struct Point { ... }    // calls the StructDecl overload
```

---

## Expansion Order

When multiple attributes are stacked on a single declaration, they expand inner to outer the attribute closest to the declaration runs first:

```kairo
@deserialize    // runs second, on the result of @serializable
@serializable   // runs first, on the original class
class Config {
    var host: string
    var port: i32
}
```

This allows attributes to compose `@serializable` can add serialization methods, and `@deserialize` can then inspect those methods to generate the inverse.

---

## Attaching Attributes

Attributes can be attached to any AST node:

```kairo
// On a function
@no_unwind
fn checksum(data: [u8;]) -> u32 { ... }

// On a class
@packed
class Header { ... }

// On a struct
@align(16)
struct SimdData { ... }

// On a block
@repeat(3)
{ std::println("repeated") }

// On a variable (if the attribute accepts VariableDecl)
@deprecated("use new_config instead")
var old_config: Config
```

An attribute can also be applied to an expression: `@name operand`, or `@name(args) operand`. The operand is one unary expression, including its calls, member accesses and initializers, so `@create Config(8080)` applies to the whole constructor call. Binary operators bind looser (`@a x + 1` is `(@a x) + 1`), and a member access on the result needs parentheses: `(@create Config(8080))->port`. At the start of a statement, an `@name` is an expression attribute when an expression follows it on the same line (`@destroy p`, `@create Config(8080)`); it attaches to the statement or declaration instead when what follows is a declaration (`@deprecated var`, `@copy fn`), a keyword statement (`@likely if`), a block (`@repeat(3) { ... }`), a loop label, or a line break.

> Expression attributes parse, but none has a meaning yet: `@create` and every other one are rejected with [SC116E](/docs/language/diagnostics/#sc116e-a-feature-is-not-yet-supported). See [Status](/docs/status/).

---

## Built-in Attributes

Kairo provides built-in attributes that are handled directly by the compiler:

### Layout attributes

| Attribute | Description | Applies to |
|---|---|---|
| `@packed` | Remove padding between members | Classes, structs, unions |
| `@align(N)` | Set minimum alignment to N bytes | Classes, structs, unions, fields, variables |

`@packed` lays the members out back to back at alignment 1, with no padding between them or at the end, as C's `__attribute__((packed))` does. `@align(N)` raises the alignment to N (it never lowers it below the natural alignment), and the size rounds up to a multiple of it. N is an integer literal, a power of two, at most 2^28; anything else is an error. On a field or a variable, `@align(N)` raises that member's or variable's alignment the same way. Together on one record, `@packed @align(N)` packs the members and aligns the whole to N, like `__attribute__((packed, aligned(N)))`.

```kairo
@packed struct P { var a: u8; var b: u32 }      // sizeof 5, alignof 1
@align(16) struct Q { var a: u8 }               // sizeof 16, alignof 16
@packed @align(4) struct PA { var a: u8; var b: u32 }   // sizeof 8, alignof 4
struct F { var a: u8; @align(8) var b: u8 }     // b at offset 8; sizeof 16
```

The layout the compiler computes for `sizeof` and `alignof` in a declaration-scope `eval if` is the same one the generated C++ has, so a branch chosen on a record's size matches the size at run time. A heap allocation of an `@align(N)` type through `create` is N-aligned: it asks the allocator for `alignof T`.

See [Classes](/docs/language/classes/#memory-layout-and-allocation) and [Structures](/docs/language/structures/#memory-layout) for layout details.

### Branch hints

| Attribute | Description | Applies to |
|---|---|---|
| `@likely` | Condition is expected to be true | `if` statements |
| `@unlikely` | Condition is expected to be false | `if` statements |
| `@unreachable` | Branch should never execute (UB if reached). Not implemented yet: rejected with [SC116E](/docs/language/diagnostics/#sc116e-a-feature-is-not-yet-supported) | `match`/`if` branches |
| `@likely` / `@unlikely` before `else` | Hint for the `else` or `else if` branch that follows | `else`, `else if` |
| `@assume(cond)` | The optimizer may take `cond` as true from here on (UB if it is false) | A statement of its own |

`@likely` and `@unlikely` also go between a branch's closing `}` and the `else` after it; each hint is for the branch it precedes. `@assume(cond)` is not an attribute on anything: it is a statement on its own line.

```kairo
@likely if a {
    fast()
} @unlikely else if b {
    rare()
} @unlikely else {
    rarer()
}

@assume(n > 0)
```

See [Control Flow](/docs/language/control-flow/#branch-hints) for branch prediction hints.

### Diagnostics

| Attribute | Description | Applies to |
|---|---|---|
| `@no_warn(CODE)` | Suppress a specific compiler warning | Any declaration |
| `@deprecated(msg)` | Mark a declaration as deprecated | Any declaration |

`@deprecated` (with no argument) or `@deprecated("message")` makes every use of the declaration a warning that names it and the message, with a note at the attribute. The declaration itself is not reported, and neither is a use inside it.

```kairo
@deprecated("use read_all instead")
fn read() -> i32 { return 0 }

fn main() -> i32 { return read() }   // warning: 'read' is deprecated: use read_all instead
```

`@no_warn(CODE, ...)` drops those warnings wherever they are reported inside the declaration, by any stage of the compiler. Each code must be a warning code (`SC031W`): an unknown code is an error, and so is an error code, since an error cannot be suppressed.

```kairo
@no_warn(SC031W)
fn f() -> i32 { var y: i32 = 1 as i32; return y }   // no redundant-cast warning
```

### Unwinding

| Attribute | Description | Applies to |
|---|---|---|
| `@unwind` | Let a C++ exception pass through this function | Functions, methods |
| `@no_unwind` | Keep the function `noexcept`, even under `-funwind` | Functions, methods |

Every Kairo function is `noexcept` in its generated C++ declaration and definition: a C++ exception that reaches a Kairo frame terminates the program (`std::terminate`). `@unwind` removes the `noexcept` from one function, so a C++ exception thrown by a C++ callee unwinds through it to the next frame up. The `-funwind` flag removes it from every Kairo function, closures included; `@no_unwind` keeps it on one function even then. Marking one function both is an error.

```kairo
fn add(a: i32, b: i32) -> i32 { return a + b }        // C++: int add(int a, int b) noexcept
@unwind fn relay(x: i32) -> i32 { return cxx_may_throw(x) }   // C++: int relay(int x)
```

Writing `@unwind` or `@no_unwind` on any one declaration of a function covers all of them: a [forward declaration](/docs/language/functions-declarations/#forward-declarations), the declaration inside a class, or the [out-of-line definition](/docs/language/classes-out-of-line/).

```kairo
class Counter {
    var n: i32
    @unwind fn get(const self) -> i32     // declared here...
}

fn Counter::get(const self) -> i32 { return self.n }   // ...so this definition is not noexcept either
```

A closure cannot carry `@unwind` yet: written before a closure, it is an expression attribute, which is not supported. A closure follows `-funwind`.

See [Exceptions](/docs/language/c-cpp-exceptions/#exceptions) for how C++ exceptions move through Kairo code.

### Function hints

| Attribute | Description | C++ | Applies to |
|---|---|---|---|
| `@hot_path` | The function runs often: optimize it for speed and keep it close to other hot code | `[[gnu::hot]]` | Functions, methods |
| `@cold_path` | The function runs rarely (error handling, setup): optimize it for size and keep it out of the way | `[[gnu::cold]]` | Functions, methods |
| `@pure` | The function's result depends only on its inputs and memory it can read, and it writes nothing else | `[[gnu::pure]]` | Functions, methods |
| `@no_inline` | Never inline the function: it keeps its own symbol and its own code, as for a benchmark kernel or a rarely taken path kept out of its caller | `__attribute__((noinline))` | Functions, methods |

```kairo
@hot_path fn next(state: *Rng) -> u64 { /* ... */ }
@cold_path fn report_failure(code: i32) { /* ... */ }
@pure fn length(v: *Vec3) -> f64 { return sqrt(v->x * v->x + v->y * v->y + v->z * v->z) }
```

Each is a promise to the optimizer, written on the function and checked where the compiler can. `@hot_path` together with `@cold_path` on one function is an error, and any of the three on something that is not a function ('`@hot_path` applies only to a function') is an error with a fix-it that removes it.

`@pure` is checked. In its body the compiler reports:

- a write to a global or `static` variable;
- an assignment through a pointer (`*p = x`, `p->field = x`, `p[i] = x`);
- a call to anything that is not a const function, another `@pure` function, an `eval fn` or a compiler intrinsic.

Reading globals and reading through pointers is allowed; that is the difference between `@pure` and a [const function](/docs/language/functions-declarations/#const-functions), which may read only its own inputs. A `@pure` function whose result changes between calls with the same arguments because something else wrote the memory it reads is fine: the optimizer only merges calls when no write could have happened in between.

### Calling conventions

| Attribute | Description | C++ | Applies to |
|---|---|---|---|
| `@preserve_most` | The callee saves nearly every general-purpose register: for a rarely taken slow path called from hot integer code | `__attribute__((preserve_most))` | `priv` functions and methods |
| `@preserve_all` | As `@preserve_most`, and the callee also saves the floating-point and vector registers | `__attribute__((preserve_all))` | `priv` functions and methods |
| `@preserve_none` | The callee saves nothing: for tail-call-heavy dispatch, such as an interpreter's opcode handlers | `__attribute__((preserve_none))` | `priv` functions and methods |

At most one per function, never on a function C or C++ can see, and only on x86-64 and AArch64. See [Calling conventions](/docs/language/functions-declarations/#calling-conventions) for the rules and the register table.

### Enums

| Attribute | Description | Applies to |
|---|---|---|
| `@open` | The enum may hold any value of its underlying type: no checked `as`, no niche | Plain enums |

A plain enum is closed by default; see [Closed and open enums](/docs/language/enums-plain/#closed-and-open-enums). `@open` on anything else is an error.

### Conversions

| Attribute | Description | Applies to |
|---|---|---|
| `@implicit` | Lets a conversion operator apply without `as` | `fn op as` in a type's body |

See [Implicit `op as`](/docs/language/operator-overloading/#implicit-op-as) for the rules.

### Other

| Attribute | Description | Applies to |
|---|---|---|
| `@core::where_handler` | Custom handler for where-clause failures. Not implemented yet | Functions |

See [Where Clauses](/docs/language/where/) for the where handler system.

### Unknown and misplaced attributes

An attribute is never accepted and ignored. An attribute name the compiler does not know is an error, `unknown attribute '@name'`, with a fix-it that removes it and a suggestion when the name is close to a built-in one (`@pakced`: did you mean `@packed`?). A built-in attribute written where it does not apply is an error that says where it does (`'@packed' applies only to a class, struct or union`), also with a fix-it that removes it. A [user-defined attribute](#defining-attributes) is rejected with [SC116E](/docs/language/diagnostics/#sc116e-a-feature-is-not-yet-supported) for now: attribute macros parse, but they are not expanded yet.

---

## The `std::AST` API

Attribute definitions interact with the AST through the `std::AST` module. This module provides types representing each kind of AST node (`FunctionDecl`, `ClassDecl`, `StructDecl`, `Block`, `VariableDecl`, etc.) and methods for inspecting and modifying them.

> [!IMPORTANT]
> The `std::AST` API is under development. The full set of node types, their fields, and available methods will be documented once the API is finalized. The examples on this page demonstrate the intended usage patterns.

Key operations available on AST nodes:

| Operation | Description |
|---|---|
| `node->name` | Access the declaration name |
| `node->body` | Access the body (for functions, blocks) |
| `node->body.append(stmt)` | Add a statement to the end |
| `node->body.prepend(stmt)` | Add a statement to the beginning |
| `node->clone()` | Deep-copy the node |
| `AST::parse!(code)` | Parse a code fragment into an AST node |
| `@create AST::T()` | Create a new AST node of type T |

---

## Macros vs Attributes

| | Macros | Attributes |
|---|---|---|
| Operates on | Raw tokens | AST nodes |
| Type awareness | No | Yes |
| Expansion time | Before parsing | After parsing |
| Can modify structure | Token substitution only | Can transform the AST |
| Syntax | `name!(args)` | `@name` on declarations |
| Must preserve node type | N/A | Yes |

Use macros for simple substitutions and [conditional compilation](/docs/language/macros-builtin/#conditional). Use attributes for structural transformations that need to inspect or modify declarations.

See [Macros](/docs/language/macros/) for the token-level macro system.

---

## Summary

```kairo
// Define an attribute
import std::AST

macro @timer(node: *AST::FunctionDecl) {
    node->body.prepend(
        AST::parse!(var __start = std::time::now())
    )
    node->body.append(
        AST::parse!(std::println(f"elapsed: {std::time::now() - __start}ms"))
    )
}

// Use an attribute
@timer
fn expensive_computation() {
    // ... work ...
}

// Attribute with arguments
macro @version(node: *AST::ClassDecl, ver: string) {
    // add a static VERSION member to the class
}

@version("2.1.0")
class MyLibrary { ... }

// Stacked attributes (inner to outer)
@json_output
@validate_fields
struct ApiResponse {
    var status: i32
    var body: string
}

// Built-in attributes
@packed
@align(16)
struct CacheLine {
    var data: [u8; 64]
}

@likely if hot_path {
    fast_operation()
}
```

## See also

- [Macros](/docs/language/macros/)
- [Built-in Macros](/docs/language/macros-builtin/)
- [Compile-Time Eval](/docs/language/eval/)
- [Structures](/docs/language/structures/#memory-layout)
- [Unions](/docs/language/unions/#memory-layout)
- [Exceptions & Panics](/docs/language/c-cpp-exceptions/)
- [Operator Overloading](/docs/language/operator-overloading/#implicit-op-as)
- [Where Clauses](/docs/language/where/)

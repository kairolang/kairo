# Attributes

Attributes are compile-time AST transformations. They modify the structure of declarations
renaming fields, injecting code, adding members with full access to the parsed syntax tree and
type information. Unlike [macros](/docs/language/macros), which operate on raw tokens before parsing,
attributes run after parsing and can inspect and modify typed AST nodes.

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

Attributes are defined with the `macro` keyword followed by `@name` and a parameter list. The first
parameter is always a pointer to the AST node being transformed:

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

Attributes must preserve the node type. An attribute attached to a function declaration receives a
`*AST::FunctionDecl` and must leave it as a function declaration it cannot replace it with a
class or a variable. This ensures the expansion process is deterministic and the AST remains
structurally consistent.

To add new nodes, create them with `std::create<AST::NodeType>()` and attach them to the existing
node (e.g., appending statements to a function body, adding members to a class).

---

## Attribute Arguments

Attributes can take additional arguments beyond the implicit node parameter:

```kairo
macro @repeat(block: *AST::Block, times: i32) {
    var original = block->clone()
    var expanded = std::create<AST::Block>()

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

Arguments are passed in parentheses after the attribute name at the use site. The node parameter is
implicit it is always the declaration or block the attribute is attached to.

---

## Overloading

Attribute definitions can be overloaded by node type or argument types. The compiler selects the
correct overload based on what the attribute is attached to:

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

When multiple attributes are stacked on a single declaration, they expand inner to outer the
attribute closest to the declaration runs first:

```kairo
@deserialize    // runs second, on the result of @serializable
@serializable   // runs first, on the original class
class Config {
    var host: string
    var port: i32
}
```

This allows attributes to compose `@serializable` can add serialization methods, and
`@deserialize` can then inspect those methods to generate the inverse.

---

## Attaching Attributes

Attributes can be attached to any AST node:

```kairo
// On a function
@inline
fn hot_path(x: i32) -> i32 { ... }

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

---

## Built-in Attributes

Kairo provides built-in attributes that are handled directly by the compiler:

### Layout attributes

| Attribute | Description | Applies to |
|---|---|---|
| `@packed` | Remove padding between members | Classes, structs, unions |
| `@align(N)` | Set minimum alignment to N bytes | Classes, structs, unions |

See [Classes](/docs/language/classes#memory-layout) and
[Structures](/docs/language/structures#memory-layout) for layout details.

### Branch hints

| Attribute | Description | Applies to |
|---|---|---|
| `@likely` | Condition is expected to be true | `if` statements |
| `@unlikely` | Condition is expected to be false | `if` statements |
| `@unreachable` | Branch should never execute (UB if reached) | `match`/`if` branches |

See [Control Flow](/docs/language/control-flow#branch-hints) for branch prediction hints.

### Diagnostics

| Attribute | Description | Applies to |
|---|---|---|
| `@no_warn(CODE)` | Suppress a specific compiler warning | Any declaration |
| `@deprecated(msg)` | Mark a declaration as deprecated | Any declaration |

### Other

| Attribute | Description | Applies to |
|---|---|---|
| `@core::where_handler` | Custom handler for where-clause failures | Functions |

See [Where Clauses](/docs/language/bounds) for the where handler system.

---

## The `std::AST` API

Attribute definitions interact with the AST through the `std::AST` module. This module provides
types representing each kind of AST node (`FunctionDecl`, `ClassDecl`, `StructDecl`, `Block`,
`VariableDecl`, etc.) and methods for inspecting and modifying them.

> [!IMPORTANT]
> The `std::AST` API is under development. The full set of node types, their fields, and available
> methods will be documented once the API is finalized. The examples on this page demonstrate the
> intended usage patterns.

Key operations available on AST nodes:

| Operation | Description |
|---|---|
| `node->name` | Access the declaration name |
| `node->body` | Access the body (for functions, blocks) |
| `node->body.append(stmt)` | Add a statement to the end |
| `node->body.prepend(stmt)` | Add a statement to the beginning |
| `node->clone()` | Deep-copy the node |
| `AST::parse!(code)` | Parse a code fragment into an AST node |
| `std::create<AST::T>()` | Create a new AST node of type T |

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

Use macros for simple substitutions and conditional compilation. Use attributes for structural
transformations that need to inspect or modify declarations.

See [Macros](/docs/language/macros) for the token-level macro system.

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

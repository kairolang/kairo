# Structures

Structs are plain data types no constructors, no methods in the body, trivially copyable via `memcpy`.
They exist for cases where you want a named bag of fields with aggregate initialization and no lifecycle
management. If you need constructors, destructors, inheritance, or virtual dispatch, use a
[class](/docs/language/classes).

---

## Declaration

```kairo
struct Point {
    var x: f64
    var y: f64
}

var p = Point { x: 1.0, y: 2.0 }
p.x   // 1.0
```

The body contains only field declarations (`var`, `const`, `eval`, `static`) and nested type definitions.
Methods and constructors are not permitted inside the struct body use
[extends](/docs/language/extends) to add behavior.

---

## Aggregate Initialization

Structs are constructed with brace-delimited field assignment. All fields must be provided unless they have
a default value at the declaration site:

```kairo
struct Color {
    var r: u8
    var g: u8
    var b: u8
    var a: u8 = 255
}

var red = Color { r: 255, g: 0, b: 0 }         // a defaults to 255
var blue = Color { r: 0, g: 0, b: 255, a: 128 } // explicit alpha
```

Field names are required in the initializer positional initialization is not supported. The order of
fields in the initializer does not need to match the declaration order.

There are no user-defined constructors. If you need construction logic, extend a factory function onto the
struct:

```kairo
extend Color {
    static fn from_hex(hex: u32) -> Color {
        return Color {
            r: (hex >> 16 & 0xFF) as u8,
            g: (hex >> 8 & 0xFF) as u8,
            b: (hex & 0xFF) as u8,
        }
    }
}

var teal = Color::from_hex(0x008080)
```

---

## Visibility

All struct members default to `pub`. You can explicitly mark a member `priv` or `prot`, but the compiler
emits a warning if you need access control on fields, a [class](/docs/language/classes) is the better
fit.

```kairo
struct Packet {
    var header: u32        // pub by default
    priv var checksum: u32 // legal but warned: consider using a class
}
```

Extended functions can be `pub`, `prot`, or `priv` without warning.

---

## `const` and `mutable` Members

`const` members must be initialized at the declaration site or in the aggregate initializer. Unlike class
`const` members, there is no constructor body to provide a one-shot assignment:

```kairo
struct Config {
    const VERSION: i32 = 1
    var name: string
}

var cfg = Config { name: "app" }
// cfg.VERSION = 2   // compile error: VERSION is const
```

`mutable` works the same as in classes the member can be modified even through a `const` reference:

```kairo
struct Metrics {
    var total: i32
    mutable var cache_hits: i32
}

fn report(const self: Metrics) {
    self.cache_hits += 1   // ok: mutable
    // self.total += 1     // compile error: total is not mutable, self is const
}
```

See [Classes](/docs/language/classes#mutable-members) for the `mutable` rationale and usage guidance.

---

## Copy Semantics

Structs are always trivially copyable. Assignment and parameter passing use `memcpy` there are no
copy constructors, move constructors, or assignment operator overloads:

```kairo
var a = Point { x: 1.0, y: 2.0 }
var b = a   // memcpy, a and b are independent copies
b.x = 9.0
a.x   // still 1.0
```

This is a hard guarantee. Extending a destructor (`fn op delete`), copy assignment (`fn op =`), or
move assignment onto a struct is a compile error. If you need custom lifecycle management, use a
[class](/docs/language/classes#the-rule-of-five).

---

## Extends

Since structs cannot contain methods in their body, behavior is added via `extend` blocks. An `extend`
block can add methods, operators, and static functions:

```kairo
struct Vec2 {
    var x: f64
    var y: f64
}

extend Vec2 {
    fn length(self) const -> f64 {
        return std::sqrt(self.x * self.x + self.y * self.y)
    }

    fn op +(self, other: Vec2) -> Vec2 {
        return Vec2 { x: self.x + other.x, y: self.y + other.y }
    }

    fn op ==(self, other: Vec2) const -> bool {
        return self.x == other.x && self.y == other.y
    }
}

var v = Vec2 { x: 3.0, y: 4.0 }
v.length()   // 5.0
```

### What extends can add

| Allowed | Not allowed |
|---|---|
| Methods | Constructors |
| Static functions | Destructors (`fn op delete`) |
| Arithmetic / comparison operators | Copy / move assignment (`fn op =`) |
| `fn op as` (type conversion) | |
| `fn op in` (iteration) | |

### Interface conformance

Structs implement interfaces through `extend ... impl`:

```kairo
interface Drawable {
    fn draw(self) -> string
}

extend Vec2 impl Drawable {
    fn draw(self) -> string {
        return f"({self.x}, {self.y})"
    }
}
```

The `extend` block and the struct definition must be in the same file the same restriction as Rust's
`impl` blocks. See [Extends](/docs/language/extends) for the full `extend` system and
[Interfaces](/docs/language/interfaces) for interface declarations.

---

## Generic Structs

Type parameters are declared in angle brackets before the struct name:

```kairo
struct <T> Pair {
    var first: T
    var second: T
}

var p = Pair<i32> { first: 10, second: 20 }
```

Generic extends must redeclare the type parameters:

```kairo
extend <T> Pair<T> {
    fn swap(self) -> Pair<T> {
        return Pair<T> { first: self.second, second: self.first }
    }
}
```

Constrain type parameters with `impl` or `derives` bounds:

```kairo
struct <T impl Comparable> Range {
    var start: T
    var end: T
}
```

See [Bounds](/docs/language/bounds) for the full constraint system.

---

## Nested Types

Structs can contain nested type definitions classes, enums, unions, other structs:

```kairo
struct Packet {
    var header: Header
    var payload: [byte]

    struct Header {
        var version: u8
        var length: u16
    }
}

var pkt = Packet {
    header: Packet::Header { version: 1, length: 64 },
    payload: [],
}
```

Nested types are accessed via `StructName::NestedType`. Interfaces cannot be nested they must be
declared at the top level.

---

## No Inheritance

Structs do not support `derives`. If you need field inheritance, embed the struct:

```kairo
struct Base {
    var x: i32
}

struct Composed {
    var base: Base
    var y: i32
}

var c = Composed { base: Base { x: 10 }, y: 20 }
c.base.x   // 10
```

This keeps aggregate initialization unambiguous and avoids layout questions that inheritance introduces.
If you need polymorphism or a type hierarchy, use [classes](/docs/language/classes#inheritance).

---

## Destructuring

Struct fields can be destructured into individual bindings:

```kairo
struct Color {
    var r: u8
    var g: u8
    var b: u8
}

var color = Color { r: 255, g: 128, b: 0 }
var { r, g, b } = color
// r = 255, g = 128, b = 0
```

Use `_` to discard fields you do not need. See
[Variables](/docs/language/variables#destructuring) for the full destructuring syntax.

---

## Memory Layout

Struct layout follows the platform's C++ ABI members in declaration order with standard padding and
alignment rules. Control layout with attributes:

```kairo
@packed
struct Tight {
    var a: u8    // offset 0
    var b: u32   // offset 1 (no padding)
}

@align(16)
struct Aligned {
    var data: [u8; 12]
}
```

Structs are always value types. A plain `var` declaration allocates on the stack. Heap allocation uses
`std::create<T>()`:

```kairo
var local = Point { x: 1.0, y: 2.0 }           // stack
var *heap = std::create<Point>(Point { x: 1.0, y: 2.0 })  // heap
```

See [Pointers](/docs/language/pointers) and [AMT](/docs/language/amt) for allocation and pointer semantics.

---

## Forward Declarations

Structs can be forward-declared for use in pointer types before the full definition is available:

```kairo
struct Node    // forward declaration

struct Tree {
    var root: unsafe *Node
}

struct Node {
    var value: i32
    var left: unsafe *Node
    var right: unsafe *Node
}
```

---

## Structs vs Classes

| | Struct | Class |
|---|---|---|
| Member default visibility | `pub` | `priv` for variables |
| Methods in body | No (use [extends](/docs/language/extends)) | Yes |
| Constructors | No (aggregate init only) | Yes |
| Destructors | No | Yes |
| Copy semantics | `memcpy` (trivial) | Rule of five |
| Inheritance | No | `derives` |
| Virtual dispatch | No | Yes |
| Aggregate initialization | Yes | No |

Use structs for plain data configuration records, protocol headers, math vectors, tuple-like types.
Use classes when you need lifecycle control, inheritance, or encapsulation.

---

## Summary

```kairo
// Basic struct
struct Point {
    var x: f64
    var y: f64
}

var p = Point { x: 1.0, y: 2.0 }

// Generic struct
struct <T> Pair {
    var first: T
    var second: T
}

// Extend with methods and operators
extend Point {
    fn length(self) const -> f64 {
        return std::sqrt(self.x * self.x + self.y * self.y)
    }

    fn op +(self, other: Point) -> Point {
        return Point { x: self.x + other.x, y: self.y + other.y }
    }
}

// Extend with interface conformance
extend Point impl Drawable {
    fn draw(self) -> string {
        return f"({self.x}, {self.y})"
    }
}

// Layout control
@packed
struct Header {
    var magic: u16
    var version: u8
    var flags: u8
}

// Composition over inheritance
struct Rect {
    var origin: Point
    var size: Point
}

var r = Rect {
    origin: Point { x: 0.0, y: 0.0 },
    size: Point { x: 100.0, y: 50.0 },
}
```
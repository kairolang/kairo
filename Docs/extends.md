# Extends

`extend` blocks add methods, operators, and static functions to types declared elsewhere. They are the
primary way to attach behavior to [structs](/docs/language/structures) and
[enums](/docs/language/enums), which cannot contain methods in their body. Classes can also be extended.

---

## Basic Syntax

```kairo
struct Point {
    var x: f64
    var y: f64
}

extend Point {
    fn length(self) const -> f64 {
        return std::sqrt(self.x * self.x + self.y * self.y)
    }

    fn op +(self, other: Point) -> Point {
        return Point { x: self.x + other.x, y: self.y + other.y }
    }

    static fn origin() -> Point {
        return Point { x: 0.0, y: 0.0 }
    }
}

var p = Point { x: 3.0, y: 4.0 }
p.length()       // 5.0
Point::origin()  // Point { x: 0.0, y: 0.0 }
```

Methods added via `extend` are called the same way as methods defined in a class body there is no
syntactic distinction at the call site.

---

## What Can Be Extended

| Type | Supports `extend` |
|---|---|
| Structs | Yes the only way to add methods |
| Enums | Yes the only way to add methods |
| Classes | Yes |
| Unions | No |
| Interfaces | No |

---

## What Extends Can Add

The rules differ by type:

### Structs

| Allowed | Not allowed |
|---|---|
| Methods | Constructors |
| Static functions | Destructors (`fn op delete`) |
| Arithmetic / comparison operators | Copy / move assignment (`fn op =`) |
| `fn op as` (type conversion) | |
| `fn op in` (iteration) | |

Structs are trivially copyable. Extending lifecycle operations (destructors, copy/move) would break
that guarantee. See [Structures](/docs/language/structures#copy-semantics).

### Enums

| Allowed | Not allowed |
|---|---|
| Methods | Constructors |
| Static functions | Destructors |
| Comparison / arithmetic operators | Copy / move assignment |
| `fn op as` (type conversion) | |

### Classes

| Allowed | Not allowed |
|---|---|
| Methods | Constructors |
| Static functions | Destructors |
| All operators | Copy / move assignment |

Classes already support methods and operators in their body. `extend` on a class is useful for
separating interface conformance or adding functionality in a different section of the codebase
(within the same file).

> [!NOTE]
> Constructors, destructors, and copy/move assignment cannot be added via `extend` on any type.
> If you need construction logic on a struct, extend a static factory function instead. If you need
> a destructor, use a [class](/docs/language/classes).

---

## Interface Conformance

`extend ... impl` declares that a type satisfies an interface and provides the required methods:

```kairo
interface Drawable {
    fn draw(self) const -> string
}

extend Point impl Drawable {
    fn draw(self) const -> string {
        return f"({self.x}, {self.y})"
    }
}
```

The compiler verifies at the `extend` declaration that all interface requirements are satisfied.
Missing methods are a compile error.

A type can conform to multiple interfaces through separate `extend` blocks:

```kairo
extend Point impl Drawable {
    fn draw(self) const -> string { ... }
}

extend Point impl Serializable {
    fn serialize(self) const -> [byte] { ... }
    fn byte_size(self) const -> i32 { ... }
}
```

See [Interfaces](/docs/language/interfaces) for interface declarations and structural conformance.

---

## Generic Extends

When extending a generic type, redeclare the type parameters:

```kairo
struct <T> Pair {
    var first: T
    var second: T
}

extend <T> Pair<T> {
    fn swap(self) -> Pair<T> {
        return Pair<T> { first: self.second, second: self.first }
    }
}
```

The type parameters in the `extend` block must match the original declaration. Constraints can be
added via `impl`, `derives`, or `where` clauses:

```kairo
extend <T impl Comparable> Pair<T> {
    fn max(self) const -> T {
        return if self.first > self.second { self.first } else { self.second }
    }
}
```

This `max` method is only available on `Pair<T>` when `T` satisfies `Comparable`. Calling
`Pair<SomeNonComparable>.max()` is a compile error.

### Generic interface conformance

```kairo
interface <T> Container {
    fn size(self) const -> i32
    fn get(self, index: i32) const -> T
}

extend <T> Pair<T> impl Container<T> {
    fn size(self) const -> i32 { return 2 }

    fn get(self, index: i32) const -> T {
        return if index == 0 { self.first } else { self.second }
    }
}
```

See [Bounds](/docs/language/bounds) for the full constraint system.

---

## Visibility

Extended methods can have `pub`, `prot`, or `priv` visibility:

```kairo
extend Point {
    pub fn distance(self, other: Point) const -> f64 {
        return (self - other).length()
    }

    priv fn validate(self) const -> bool {
        return self.x >= 0.0 && self.y >= 0.0
    }
}
```

The default visibility for extended methods matches the type's convention `pub` for struct and
enum extensions, `pub` for class method extensions.

---

## `Self` in Extend Blocks

`Self` is available in `extend` blocks and resolves to the extended type:

```kairo
extend <T> Pair<T> {
    fn duplicate(self) const -> Self {
        // Self resolves to Pair<T>
        return Pair<T> { first: self.first, second: self.second }
    }
}
```

---

## Same-File Restriction

A plain `extend` block must be in the same file as the type definition:

```kairo
// point.k
struct Point { var x: f64; var y: f64 }

extend Point {
    fn length(self) const -> f64 { ... }   // ok: same file as Point
}
```

```kairo
// other.k
import point::Point

// extend Point { ... }   // compile error: Point is defined in a different file
```

For `extend ... impl` blocks (interface conformance), the rule is looser: either the type or the
interface must be defined in the same file as the `extend` block:

```kairo
// drawable.k
import point::Point

interface Drawable {
    fn draw(self) const -> string
}

// This is legal even though Point is defined in point.k,
// because Drawable is defined here:
extend Point impl Drawable {
    fn draw(self) const -> string {
        return f"({self.x}, {self.y})"
    }
}
```

This prevents conflicts between extensions in different files while still allowing interface
conformance to be declared where the interface is defined.

---

## Multiple Extend Blocks

A type can have multiple `extend` blocks in the same file. Each block can target different
interfaces or group related functionality:

```kairo
struct Color {
    var r: u8
    var g: u8
    var b: u8
}

// Arithmetic operations
extend Color {
    fn op +(self, other: Color) -> Color {
        return Color {
            r: (self.r as i32 + other.r as i32).min(255) as u8,
            g: (self.g as i32 + other.g as i32).min(255) as u8,
            b: (self.b as i32 + other.b as i32).min(255) as u8,
        }
    }
}

// Serialization
extend Color impl Serializable {
    fn serialize(self) const -> [byte] { ... }
    fn byte_size(self) const -> i32 { return 3 }
}

// Display
extend Color impl Drawable {
    fn draw(self) const -> string {
        return f"rgb({self.r}, {self.g}, {self.b})"
    }
}
```

---

## Extend vs Class Methods

For classes, there is no semantic difference between a method in the class body and a method in an
`extend` block both produce the same compiled output. The choice is organizational:

```kairo
class Server {
    var port: i32

    fn Server(self, port: i32) { self.port = port }

    // Core functionality in the class body
    fn start(self) { ... }
    fn stop(self) { ... }
}

// Interface conformance separated
extend Server impl Loggable {
    fn to_log_string(self) const -> string {
        return f"Server(:{self.port})"
    }
}
```

---

## Summary

```kairo
// Extend a struct with methods
struct Vec2 { var x: f64; var y: f64 }

extend Vec2 {
    fn length(self) const -> f64 = std::sqrt(self.x * self.x + self.y * self.y)
    fn op +(self, other: Vec2) -> Vec2 = Vec2 { x: self.x + other.x, y: self.y + other.y }
    static fn zero() -> Vec2 = Vec2 { x: 0.0, y: 0.0 }
}

// Extend an enum with methods
extend Direction {
    fn opposite(self) -> Direction {
        match self {
            case .North { return .South }
            case .South { return .North }
            case .East  { return .West }
            case .West  { return .East }
        }
    }
}

// Interface conformance
extend Vec2 impl Drawable {
    fn draw(self) const -> string = f"({self.x}, {self.y})"
}

// Generic extend with constraints
extend <T impl Comparable> Pair<T> {
    fn max(self) const -> T = if self.first > self.second { self.first } else { self.second }
}
```
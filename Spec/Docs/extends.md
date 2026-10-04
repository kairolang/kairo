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
    fn length(const self) -> f64 {
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

An `extend` body is the extended type's scope. Members still need an explicit qualifier `self.x` or `Self::x`, exactly as in a class body (see [Members always need a qualifier](/docs/language/classes#members-always-need-a-qualifier)) and the same one exception applies: the target's nested types and type aliases are visible unqualified.

```kairo
class Tree {
    struct Node { var value: i32 }
    var count: i32
}

extend Tree {
    fn add(self) {
        var n = Node { value: 0 }   // ok: `Node` means `Self::Node`
        self.count += 1             // ok
        // count += 1               // error: needs `self.`
    }
}
```

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
| `fn op in` (iteration) | Member-only operators (`as`, `[]`, `->`) |

Structs are trivially copyable. Extending lifecycle operations (destructors, copy/move) would break
that guarantee. See [Structures](/docs/language/structures#copy-semantics).

### Enums

| Allowed | Not allowed |
|---|---|
| Methods | Constructors |
| Static functions | Destructors |
| Comparison / arithmetic operators | Copy / move assignment |
| | Member-only operators (`as`, `[]`, `->`) |

### Classes

| Allowed | Not allowed |
|---|---|
| Methods | Constructors |
| Static functions | Destructors |
| Operators other than the member-only ones | Copy / move assignment |
| | Member-only operators (`as`, `[]`, `->`, `delete`) |

Classes already support methods and operators in their body. `extend` on a class is useful for
separating interface conformance or adding functionality in a different section of the codebase
(within the same file).

> [!NOTE]
> Constructors, destructors, and copy/move assignment cannot be added via `extend` on any type. Neither
> can the member-only operators `as`, `[]`, `->`, and `delete`; declare them in the type's own body.
> If you need construction logic on a struct, extend a static factory function instead. If you need
> a destructor, use a [class](/docs/language/classes).

---

## Interface Conformance

`extend ... impl` declares that a type satisfies an interface and provides the required methods:

```kairo
interface Drawable {
    fn draw(const self) -> string
}

extend Point impl Drawable {
    fn draw(const self) -> string {
        return f"({self.x}, {self.y})"
    }
}
```

The compiler verifies at the `extend` declaration that all interface requirements are satisfied.
Missing methods are a compile error.

> [!NOTE]
> The current compiler does not report missing methods at the `extend` declaration yet. See [Implementation Status](/docs/status#not-diagnosed).

A type can conform to multiple interfaces through separate `extend` blocks:

```kairo
extend Point impl Drawable {
    fn draw(const self) -> string { ... }
}

extend Point impl Serializable {
    fn serialize(const self) -> [byte] { ... }
    fn byte_size(const self) -> i32 { ... }
}
```

See [Interfaces](/docs/language/interfaces) for interface declarations and structural conformance.

---

## Generic Extends

A generic `extend` declares its own type parameters:

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

The parameters belong to the `extend` block, not to the type. Its target can be any instance pattern of
the type, so an extension can apply to only some instantiations:

```kairo
struct <T> Box {
    var value: T
}

struct <T> Wrap {
    var inner: T
}

extend <T> Wrap<Box<T>> {
    fn unbox(const self) -> T {   // only on Wrap<Box<X>>
        return self.inner.value
    }
}
```

`Wrap<Box<i32>>` has `unbox`; `Wrap<i32>` does not.

Constraints on an extension's parameters are written with `impl`, `derives`, or a
[`requires` clause](/docs/language/requires):

```kairo
extend <T impl Comparable> Pair<T> {
    fn max(const self) -> T {
        return if self.first > self.second { self.first } else { self.second }
    }
}
```

This `max` method is only available on `Pair<T>` when `T` satisfies `Comparable`. Calling
`pair_of_noncomparable.max()` (or `Pair<SomeNonComparable>::max(p)`) is a compile error.

> [!NOTE]
> The current compiler does not check an extension's bounds at the call site yet. See [Implementation Status](/docs/status#not-diagnosed).

### Generic interface conformance

```kairo
interface <T> Container {
    fn size(const self) -> i32
    fn get(const self, index: i32) -> T
}

extend <T> Pair<T> impl Container<T> {
    fn size(const self) -> i32 { return 2 }

    fn get(const self, index: i32) -> T {
        return if index == 0 { self.first } else { self.second }
    }
}
```

See [Requires Clauses](/docs/language/requires) for the full constraint system.

---

## Visibility

Extended methods can have `pub`, `prot`, or `priv` visibility:

```kairo
extend Point {
    pub fn distance(const self, other: Point) -> f64 {
        return (self - other).length()
    }

    priv fn validate(const self) -> bool {
        return self.x >= 0.0 && self.y >= 0.0
    }
}
```

An extension member with no modifier is `pub`. A `priv` extension member is visible only inside the
file that contains the `extend` block, not everywhere the type is visible. `prot` has its usual
library-internal meaning.

---

## `Self` in Extend Blocks

`Self` is available in `extend` blocks and resolves to the extended type:

```kairo
extend <T> Pair<T> {
    fn duplicate(const self) -> Self {
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
    fn length(const self) -> f64 { ... }   // ok: same file as Point
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
    fn draw(const self) -> string
}

// This is legal even though Point is defined in point.k,
// because Drawable is defined here:
extend Point impl Drawable {
    fn draw(const self) -> string {
        return f"({self.x}, {self.y})"
    }
}
```

This prevents conflicts between extensions in different files while still allowing interface
conformance to be declared where the interface is defined.

> [!NOTE]
> The current compiler does not reject an `extend` in the wrong file yet. See [Implementation Status](/docs/status#not-diagnosed).

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
    fn serialize(const self) -> [byte] { ... }
    fn byte_size(const self) -> i32 { return 3 }
}

// Display
extend Color impl Drawable {
    fn draw(const self) -> string {
        return f"rgb({self.r}, {self.g}, {self.b})"
    }
}
```

---

## Extend vs Class Methods

A method in the class body and a method in an `extend` block are called the same way, but they are
different entities:

- An extension member is not virtual, cannot override, and cannot be a constructor, destructor, or
  assignment operator.
- A same-file `extend` can read the type's private members. An `extend ... impl` placed in the
  interface's file cannot.
- C++ code calling a Kairo type sees body methods as member functions, and extension members as static
  functions of a companion scope.

Put anything that needs dynamic dispatch, overriding, or lifecycle behavior in the body. Use `extend`
for the rest, such as interface conformance kept apart from the core type:

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
    fn to_log_string(const self) -> string {
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
    fn length(const self) -> f64 = std::sqrt(self.x * self.x + self.y * self.y)
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
    fn draw(const self) -> string = f"({self.x}, {self.y})"
}

// Generic extend with constraints
extend <T impl Comparable> Pair<T> {
    fn max(const self) -> T = if self.first > self.second { self.first } else { self.second }
}
```
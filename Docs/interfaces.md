# Interfaces

Interfaces define a set of method signatures that a type must satisfy. They are zero-cost conformance
contracts no vtable, no runtime dispatch, no storage overhead. A type conforms to an interface if it
has all the required methods with matching signatures, whether or not it explicitly declares conformance.

---

## Declaration

```kairo
interface Serializable {
    fn serialize(self) const -> [byte]
    fn byte_size(self) const -> i32
}
```

An interface body contains method signatures, static function signatures, and operator signatures. No
method bodies, no variables, no constants, no nested types. Every member is implicitly `pub` the
`priv` and `prot` modifiers are compile errors on interface members. Explicit `pub` is permitted but
has no effect.

---

## Conformance

A type declares interface conformance with `impl` on a [class](/docs/language/classes) or through
`extend ... impl` on a [struct](/docs/language/structures), [enum](/docs/language/enums), or class. The
compiler verifies at declaration time that all required methods are present with matching signatures:

```kairo
class Document impl Serializable {
    var content: string

    fn Document(self, content: string) {
        self.content = content
    }

    fn serialize(self) const -> [byte] {
        return self.content.to_bytes()
    }

    fn byte_size(self) const -> i32 {
        return self.content.len()
    }
}
```

> [!NOTE]
> Conformance is structural, not nominal. A type that has all the required methods with matching signatures satisfies the interface implicitly. The check happens at the point of use. See [Structural conformance](#structural-conformance) section below for details.

For structs and enums, conformance goes through `extend`:

```kairo
struct Point {
    var x: f64
    var y: f64
}

extend Point impl Serializable {
    fn serialize(self) const -> [byte] {
        // serialization logic
    }

    fn byte_size(self) const -> i32 {
        return 16   // two f64s
    }
}
```

See [Extends](/docs/language/extends) for the full `extend` system.

### Structural conformance

Explicit `impl` is not required. A type that has all the required methods with matching signatures
satisfies the interface implicitly. The check happens at the point of use:

```kairo
class Logger {
    fn serialize(self) const -> [byte] { ... }
    fn byte_size(self) const -> i32 { ... }
}

// Logger never mentions Serializable, but satisfies it structurally

fn <T impl Serializable> write_to_disk(data: T) { ... }

write_to_disk(Logger())   // compiles: Logger has serialize() and byte_size()
```

The difference between explicit and implicit conformance is when the check happens at declaration
time (`class Foo impl Bar`) or at first use (`fn <T impl Bar>`). The runtime behavior is identical.

---

## Generic Interfaces

Interfaces can declare type parameters:

```kairo
interface <T> Container {
    fn add(self, item: T)
    fn get(self, index: i32) const -> T
    fn size(self) const -> i32
}

class IntBuffer impl Container<i32> {
    var data: [i32]

    fn IntBuffer(self) { self.data = [] }

    fn add(self, item: i32) {
        self.data.push(item)
    }

    fn get(self, index: i32) const -> i32 {
        return self.data[index]
    }

    fn size(self) const -> i32 {
        return self.data.len()
    }
}
```

Type parameters on interfaces can have constraints:

```kairo
interface <T impl Comparable, U derives Base> Registry {
    fn lookup(self, key: T) const -> U
    fn store(self, key: T, value: U)
}
```

Generic defaults are not permitted on interface type parameters.

See [Bounds](/docs/language/bounds) for the full constraint system.

---

## Operators in Interfaces

Interfaces can require operator overloads:

```kairo
interface Equatable {
    fn op ==(self, other: Self) const -> bool
}

interface Convertible {
    fn op as(self) -> string
}
```

`Self` in an interface signature refers to the conforming type. A class that `impl Equatable` must
provide `fn op ==(self, other: Self) const -> bool` where `Self` resolves to that class.

See [Operators](/docs/language/operators#operator-overloading) for the full list of overloadable
operators.

---

## Constructors in Interfaces

Interfaces can require constructor signatures:

```kairo
interface Defaultable {
    fn Defaultable(self)
}

interface <T> Cloneable {
    fn Cloneable(self, source: T)
}
```

A conforming type must have a constructor that matches the parameter list. The constructor name in the
implementation uses the type's own name, not the interface name:

```kairo
class Config impl Defaultable {
    var timeout: i32

    fn Config(self) {           // satisfies Defaultable's constructor requirement
        self.timeout = 30
    }
}
```

---

## Static Methods in Interfaces

Interfaces can require static methods:

```kairo
interface <T> Parseable {
    static fn from_string(input: string) -> T
    static fn from_bytes(data: [byte]) -> T
}

class Timestamp impl Parseable<Timestamp> {
    var epoch: i64

    fn Timestamp(self, epoch: i64) {
        self.epoch = epoch
    }

    static fn from_string(input: string) -> Timestamp {
        // parsing logic
        return Timestamp(0)
    }

    static fn from_bytes(data: [byte]) -> Timestamp {
        // parsing logic
        return Timestamp(0)
    }
}
```

---

## Return Types with `Self`

Interface methods can use `Self` as a return type. `Self` always refers to a reference to the
conforming type:

```kairo
interface Chainable {
    fn then(self, next: Self) -> Self
}

class Pipeline impl Chainable {
    fn then(self, next: Self) -> Self {
        // Self resolves to Pipeline here
        // returns a reference to Pipeline
    }
}
```

For returning a copy or a pointer, use the interface name or a pointer to it:

```kairo
interface <T> Factory {
    static fn create() -> *T    // returns a pointer to the conforming type
}
```

---

## Interface Inheritance

Interfaces can inherit from other interfaces with `derives`. A type that conforms to the derived
interface must satisfy all inherited interfaces as well:

```kairo
interface Readable {
    fn read(self, buffer: [byte], count: i32) -> i32
}

interface Seekable {
    fn seek(self, position: i64)
    fn tell(self) const -> i64
}

interface Stream derives Readable, Seekable {
    fn close(self)
    fn flush(self)
}
```

A class that `impl Stream` must provide `read`, `seek`, `tell`, `close`, and `flush`:

```kairo
class FileStream impl Stream {
    var fd: i32

    fn FileStream(self, path: string) { ... }

    fn read(self, buffer: [byte], count: i32) -> i32 { ... }
    fn seek(self, position: i64) { ... }
    fn tell(self) const -> i64 { ... }
    fn close(self) { ... }
    fn flush(self) { ... }
}
```

Interface inheritance is purely additive the derived interface's requirements are the union of its
own methods and all inherited methods. There is no diamond problem because interfaces carry no
implementation or state.

Multiple inheritance is permitted:

```kairo
interface Loggable derives Serializable, Printable {
    fn log_level(self) const -> i32
}
```

---

## Using Interfaces as Bounds

The primary use of interfaces is constraining generic type parameters with `impl`:

```kairo
fn <T impl Serializable> save(data: T, path: string) {
    var bytes = data.serialize()
    write_file(path, bytes)
}
```

`impl` checks structural conformance the type satisfies the interface's required method signatures.
This is distinct from `derives`, which checks class inheritance. See [Bounds](/docs/language/bounds)
for the full constraint system.

```kairo
fn <T impl Serializable> save(data: T) { ... }   // T has serialize() and byte_size()
fn <T derives Base> process(data: T) { ... }       // T is a subclass of Base
```

---

## Top-Level Only

Interfaces must be declared at the top level of a file. They cannot be nested inside classes, structs,
enums, or other interfaces:

```kairo
interface Valid {
    fn check(self) const -> bool
}

class Outer {
    // interface Invalid { ... }   // compile error: interfaces cannot be nested
}
```

---

## No Default Implementations

Interface methods have no bodies. Every method is a requirement that the conforming type must fulfill:

```kairo
interface Hashable {
    fn hash(self) const -> u64
    // fn hash(self) const -> u64 { return 0 }   // compile error: no default implementations
}
```

This keeps interfaces as zero-cost contracts. There is no method resolution order, no inheritance
of behavior, and no hidden dispatch. If you need shared implementation, use a base
[class](/docs/language/classes) with `derives`.

---

## No Variables or Constants

Interfaces cannot declare variables, constants, static variables, or eval bindings:

```kairo
interface Invalid {
    // var x: i32              // compile error
    // const Y: i32 = 10      // compile error
    // static z: i32 = 0      // compile error
    fn valid_method(self)      // ok
}
```

---

## Summary

```kairo
// Basic interface
interface Drawable {
    fn draw(self) const -> string
    fn bounds(self) const -> (f64, f64, f64, f64)
}

// Generic interface with constraints
interface <T impl Comparable> SortedContainer {
    fn insert(self, item: T)
    fn min(self) const -> T
    fn max(self) const -> T
}

// Interface with operators
interface Arithmetic {
    fn op +(self, other: Self) -> Self
    fn op -(self, other: Self) -> Self
    fn op ==(self, other: Self) const -> bool
}

// Interface inheritance
interface Flushable {
    fn flush(self)
}

interface BufferedWriter derives Flushable {
    fn write(self, data: [byte])
    fn buffer_size(self) const -> i32
}

// Class conformance
class Renderer impl Drawable {
    fn draw(self) const -> string { return "rendering" }
    fn bounds(self) const -> (f64, f64, f64, f64) { return (0.0, 0.0, 100.0, 100.0) }
}

// Struct conformance via extend
extend Point impl Drawable {
    fn draw(self) const -> string { return f"({self.x}, {self.y})" }
    fn bounds(self) const -> (f64, f64, f64, f64) { return (self.x, self.y, self.x, self.y) }
}

// Generic bound
fn <T impl Drawable> render_all(items: [T]) {
    for item in items {
        std::println(item.draw())
    }
}
```
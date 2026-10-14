# Interfaces

Interfaces define a set of method signatures that a type must satisfy. An interface used as a bound
is zero-cost: it is checked at compile time and leaves nothing in the binary. Using an interface for
runtime dispatch, via a witness table, is described in [Virtual Interfaces](#virtual-interfaces). A
type conforms to an interface if it has all the required methods with matching signatures, whether or
not it explicitly declares conformance.

For runtime polymorphism over a class hierarchy, use a base [class](/docs/language/classes) with
`virtual` methods and dispatch through a base pointer. Interfaces and virtual dispatch solve different
problems and can be used together on the same type.

---

## Declaration

```kairo
interface Serializable {
    fn serialize(const self) -> string
    fn byte_size(const self) -> i32
}
```

An interface body contains method signatures (including generic methods), static function signatures,
operator signatures, constructor requirements, and [associated types](#associated-types). It has no
method bodies, variables, constants, or nested classes, structs, enums or interfaces. Every member is implicitly `pub` the
`priv` and `prot` modifiers are compile errors on interface members. Explicit `pub` is permitted but
has no effect.

---

## Conformance

A type declares interface conformance with `impl` on a [class](/docs/language/classes) or through
`extend ... impl` on a [struct](/docs/language/structures), [enum](/docs/language/enums), or class. The
compiler verifies at declaration time that all required methods are present with matching signatures:

```kairo
interface Serializable {
    fn serialize(const self) -> string
    fn byte_size(const self) -> i32
}

class Document impl Serializable {
    var content: string
    var size: i32

    fn Document(self, content: string, size: i32) {
        self.content = content
        self.size = size
    }

    fn serialize(const self) -> string {
        return self.content
    }

    fn byte_size(const self) -> i32 {
        return self.size
    }
}
```

> [!NOTE]
> Conformance is structural, not nominal. A type that has all the required methods with matching signatures satisfies the interface implicitly. The check happens at the point of use. See [Structural conformance](#structural-conformance) section below for details.

For structs and enums, conformance goes through `extend`:

```kairo
interface Serializable {
    fn serialize(const self) -> string
    fn byte_size(const self) -> i32
}

struct Point {
    var x: f64
    var y: f64
}

extend Point impl Serializable {
    fn serialize(const self) -> string {
        return f"{self.x},{self.y}"
    }

    fn byte_size(const self) -> i32 {
        return 16   // two f64s
    }
}
```

See [Extends](/docs/language/extends) for the full `extend` system.

### Structural conformance

Explicit `impl` is not required. A type that has all the required methods with matching signatures
satisfies the interface implicitly. The check happens at the point of use:

```kairo
interface Serializable {
    fn serialize(const self) -> string
    fn byte_size(const self) -> i32
}

class Logger {
    fn serialize(const self) -> string { return "log" }
    fn byte_size(const self) -> i32 { return 3 }
}

// Logger never mentions Serializable, but satisfies it structurally

fn <T impl Serializable> write_to_disk(data: T) -> i32 { return data.byte_size() }

fn main() -> i32 {
    write_to_disk(Logger())   // compiles: Logger has serialize() and byte_size()
    return 0
}
```

The difference between explicit and implicit conformance is when the check happens at declaration
time (`class Foo impl Bar`) or at first use (`fn <T impl Bar>`). The runtime behavior is identical.

### Signature matching

A generic method requirement is matched by a
method with the same number of generic parameters and the same bounds, whose signature is identical
once its parameters are renamed: `fn <U> liz(self)` satisfies `fn <T> liz(self)`.

```kairo
interface Serializable {
    fn serialize(const self) -> string
    fn byte_size(const self) -> i32
}

interface Sink {
    fn <T impl Serializable> push(self, item: T)
}

class Buffer impl Sink {
    fn <U impl Serializable> push(self, item: U) { }   // ok: same shape, U renamed from T
}
```

---

## Generic Interfaces

Interfaces can declare type parameters:

```kairo
interface <T> Container {
    fn add(self, item: T)
    fn get(const self, index: i32) -> T
    fn size(const self) -> i32
}

class IntPair impl Container<i32> {
    var items: [i32; 2]
    var count: i32

    fn IntPair(self) { self.count = 0 }

    fn add(self, item: i32) {
        self.items[self.count] = item
        self.count += 1
    }

    fn get(const self, index: i32) -> i32 {
        return self.items[index]
    }

    fn size(const self) -> i32 {
        return self.count
    }
}
```

Type parameters on interfaces can have constraints:

```kairo
interface Comparable {
    fn op <(const self, other: Self) -> bool
}

class Base { }

interface <T impl Comparable, U derives Base> Registry {
    fn lookup(const self, key: T) -> U
    fn store(self, key: T, value: U)
}
```

Generic defaults are not permitted on interface type parameters. (An [associated type](#associated-types)
may have a default; that is a different thing, chosen by the conforming type rather than by the user
of the interface.)

See [Requires Clauses](/docs/language/requires) for the full constraint system.

---

## Associated Types

> [!NOTE]
> Associated types are not compiled yet. See [Status](/docs/status#not-compiled-yet).

An interface can require a type member. A conforming type supplies it with a type alias:

```kairo
interface Graph {
    type Node
    type Edge
    fn edges(const self, n: Self::Node) -> [Self::Edge]
}

class RoadMap impl Graph {
    type Node = CityId
    type Edge = Road

    fn edges(const self, n: CityId) -> [Road] { ... }
}
```

A generic body names it through its parameter: `T::Node`. Associated types can carry bounds, and can
themselves be generic:

```kairo
interface Store {
    type <K impl Hashable> Map
    fn <K impl Hashable> index(const self) -> Self::Map<K>
}
```

A generic body names a generic associated type with its arguments: `T::Map<K>`.

### Defaults

An associated type may have a default:

```kairo
interface Indexed {
    type Index = usize
    fn at(const self, i: Self::Index) -> i32
}
```

The default applies only when a type conforms explicitly, with `impl` on its declaration or through
`extend ... impl`, and doesn't declare the type itself. Structural conformance never uses defaults: a
type that satisfies an interface implicitly must declare every associated type.

A default may refer to `Self` and to associated types declared before it in the same interface. Defaults
resolve in declaration order; a forward reference, and therefore any cycle, is a compile error:

```kairo
interface WeightedGraph {
    type Node
    type Edge = (Self::Node, Self::Node)   // ok: Node is declared earlier
    // type Cost = Self::Weight             // compile error: Weight is declared later
    type Weight
}
```

A default must satisfy its own bounds. This is checked once, at the interface declaration, with `Self`
abstract, not separately for each conforming type.

### Associated types and inheritance

A derived interface may give an inherited associated type a default if it has none. It may not change
a default that is already given; otherwise which default applies would depend on the inheritance path.

### Name collisions between bounds

Associated types belong to their interface. If `Graph` and `Tree` both declare `Node`, then for the same
`T`, `Graph`'s `Node` and `Tree`'s `Node` are different types. In a body bounded by both, `T::Node` is
ambiguous and is a compile error; it must be written with a qualified form that names the interface. The
qualified syntax is not fixed yet. It is needed only when the names collide.

---

## Operators in Interfaces

Interfaces can require operator overloads:

```kairo
interface Equatable {
    fn op ==(const self, other: Self) -> bool
}

interface Convertible {
    fn op as(self) -> string
}
```

`Self` in an interface signature refers to the conforming type. A class that `impl Equatable` must
provide `fn op ==(const self, other: Self) -> bool` where `Self` resolves to that class.

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
interface Defaultable {
    fn Defaultable(self)
}

class Config impl Defaultable {
    var timeout: i32

    fn Config(self) {           // satisfies Defaultable's constructor requirement
        self.timeout = 30
    }
}
```

### Lifecycle attributes on constructor requirements

Constructor requirements can carry `@copy` or `@move` attributes to require a specific lifecycle
category. This is how you express "T must be copyable" or "T must be movable" as an interface bound:

```kairo
interface Copyable {
    @copy
    fn Copyable(self, const other: Self)
}

interface Movable {
    @move
    fn Movable(self, other: Self)
}

fn <T impl Copyable> store(item: T) -> T { return item }
fn <T impl Movable> consume(item: T)     { }
```

A `@copy` requirement is satisfied only by COPY types. A `@move` requirement is satisfied by COPY and
MOVE types; a copy is a valid move. NON_TRANSFER types satisfy neither.

Keep lifecycle requirements separate from a default constructor requirement. Putting `fn Copyable(self)`
in `Copyable` would make "copyable" also mean "default-constructible", and the bound would reject every
copyable type without a default constructor. Require default construction separately, with
`Defaultable` above, where a body needs it.

The standard library will provide canonical lifecycle interfaces; these are just examples. See [Lifecycle Categories](/docs/language/classes#lifecycle-categories) for the underlying model.

---

## Static Methods in Interfaces

Interfaces can require static methods:

```kairo
interface Parseable {
    static fn from_string(input: string) -> Self
    static fn from_bytes(data: [byte]) -> Self
}

class Timestamp impl Parseable {
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

Interface methods can use `Self` as a return type. `Self` resolves to the conforming type a class
that `impl Chainable` and returns `Self` returns its own type:

```kairo
interface Chainable {
    fn then(self, next: Self) -> Self
}

class Pipeline impl Chainable {
    fn then(self, next: Self) -> Self {
        // Self resolves to Pipeline
        return self
    }
}
```

Kairo has no user-visible reference types [Tether](/docs/language/tether) infers reference semantics where
needed. In practice this means `Self` returns enable fluent chaining without `->` or explicit
dereferencing:

```kairo
interface Chainable {
    fn then(self, next: Self) -> Self
}

class Pipeline impl Chainable {
    var steps: i32

    fn Pipeline(self) { self.steps = 0 }

    fn then(self, next: Self) -> Self {
        self.steps += 1
        return self
    }

    fn run(self) -> i32 { return self.steps }
}

fn main() -> i32 {
    var other = Pipeline()
    var another = Pipeline()
    return Pipeline().then(other).then(another).run()
}
```

To return a pointer to the conforming type, use `*Self`:

```kairo
interface Duplicable {
    fn clone(self) -> *Self
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
    fn tell(const self) -> i64
}

interface Stream derives Readable, Seekable {
    fn close(self)
    fn flush(self)
}
```

A class that `impl Stream` must provide `read`, `seek`, `tell`, `close`, and `flush`:

```kairo
interface Readable {
    fn read(self, buffer: [byte], count: i32) -> i32
}

interface Seekable {
    fn seek(self, position: i64)
    fn tell(const self) -> i64
}

interface Stream derives Readable, Seekable {
    fn close(self)
    fn flush(self)
}

class FileStream impl Stream {
    var fd: i32
    var pos: i64

    fn FileStream(self, fd: i32) {
        self.fd = fd
        self.pos = 0
    }

    fn read(self, buffer: [byte], count: i32) -> i32 { return 0 }
    fn seek(self, position: i64) { self.pos = position }
    fn tell(const self) -> i64 { return self.pos }
    fn close(self) { self.fd = -1 }
    fn flush(self) { }
}
```

Interface inheritance is purely additive the derived interface's requirements are the union of its
own methods and all inherited methods. There is no diamond problem because interfaces carry no
implementation or state. Associated type defaults follow a rule that keeps it that way; see
[Associated types and inheritance](#associated-types-and-inheritance).

Multiple inheritance is permitted:

```kairo
interface Serializable {
    fn serialize(const self) -> string
    fn byte_size(const self) -> i32
}

interface Printable {
    fn print(const self) -> string
}

interface Loggable derives Serializable, Printable {
    fn log_level(const self) -> i32
}
```

---

## Using Interfaces as Bounds

The primary use of interfaces is constraining generic type parameters with `impl`:

```kairo
interface Serializable {
    fn serialize(const self) -> string
    fn byte_size(const self) -> i32
}

fn write_file(path: string, text: string) { }

fn <T impl Serializable> save(data: T, path: string) {
    var text = data.serialize()
    write_file(path, text)
}
```

`impl` checks structural conformance the type satisfies the interface's required method signatures.
This is distinct from `derives`, which checks class inheritance. See [Requires Clauses](/docs/language/requires)
for the full constraint system.

```kairo
interface Serializable {
    fn serialize(const self) -> string
    fn byte_size(const self) -> i32
}

class Base { }

fn <T impl Serializable> save(data: T) -> i32 { return data.byte_size() }   // T has serialize() and byte_size()
fn <T derives Base> process(data: T) { }                                    // T is a subclass of Base
```

---

## Generic Bodies

Inside `fn <T impl Foo>`, a value of type `T` supports exactly what `Foo` (and every interface it derives)
declares, plus destruction and move, which every type parameter has unless it opts out (see
[Implicit capabilities](/docs/language/classes#type-parameter-constraints)).

- `x.method()` resolves against `Foo`'s methods.
- A generic method requirement is called with explicit arguments, `x.liz<i32>()`, or with deduced ones.
- `var x: T` with no initializer requires a constructor requirement `fn Foo(self)` in some bound.
- `T::Name` names an [associated type](#associated-types).

Nothing else is available, and the body is checked once against its bounds, never per instantiation.

```kairo
interface Shape {
    fn area(const self) -> f64
}

fn <T impl Shape> describe(s: T) -> f64 {
    var a = s.area()     // ok: declared by Shape
    // s.perimeter()     // compile error: Shape declares no perimeter()
    // var t: T          // compile error: no bound requires a default constructor
    return a
}
```

> [!NOTE]
> The current compiler does not report `var x: T` without a constructor bound yet. See
> [Status](/docs/status#not-diagnosed).

See [Generic Classes](/docs/language/classes#type-parameter-constraints) for the implicit destroy and
move capabilities and how instantiation reports them.

---

## Virtual Interfaces

An interface declared `virtual interface` can also be used for runtime dispatch. A pointer to it,
`*Allocator`, can point at a value of any conforming type; calls through the pointer go through a
witness table built for each conforming type, so the caller doesn't need to know at compile time which
type it holds:

> [!NOTE]
> Virtual interfaces are not compiled yet. See [Status](/docs/status#not-compiled-yet).

```kairo
virtual interface Allocator {
    fn alloc(self, size: usize, align: usize) -> unsafe *u8
    fn free(self, ptr: unsafe *u8, size: usize)
}

class LibcAllocator impl Allocator {
    fn alloc(self, size: usize, align: usize) -> unsafe *u8 { return &null }
    fn free(self, ptr: unsafe *u8, size: usize) { }
}

fn release(alloc: *Allocator, ptr: unsafe *u8, size: usize) {
    alloc->free(ptr, size)   // dispatched through LibcAllocator's (or any conformer's) witness table
}
```

A virtual interface is still an ordinary interface when used as a bound: `fn <T impl Allocator>` is
checked at compile time and costs nothing. The witness table is paid for only where the interface is
used for runtime dispatch.

---

## Declaration Scope

Interfaces must be declared at module scope. They cannot be nested inside classes, structs, enums, or
other interfaces:

```kairo
interface Valid {
    fn check(const self) -> bool
}

class Outer {
    // interface Invalid { ... }   // compile error: interfaces cannot be nested
}
```

See [Modules](/docs/language/modules) for module organization.

---

## No Default Implementations

Interface methods have no bodies. Every method is a requirement that the conforming type must fulfill:

```kairo
interface Hashable {
    fn hash(const self) -> u64
    // fn hash(const self) -> u64 { return 0 }   // compile error: no default implementations
}
```

This keeps interfaces as zero-cost contracts. There is no method resolution order, no inheritance
of behavior, and no hidden dispatch when an interface is used as a bound. If you need shared implementation, use a base
[class](/docs/language/classes) with `derives`.

---

## No Variables or Constants

Interfaces cannot declare variables, constants, static variables, or eval bindings:

```kairo
interface Invalid {
    // var x: i32             // compile error
    // const Y: i32 = 10      // compile error
    // static z: i32 = 0      // compile error
    fn valid_method(self)     // ok
}
```

---

## Summary

```kairo
// Basic interface
interface Drawable {
    fn draw(const self) -> string
    fn width(const self) -> f64
}

interface Comparable {
    fn op <(const self, other: Self) -> bool
}

// Generic interface with constraints
interface <T impl Comparable> SortedContainer {
    fn insert(self, item: T)
    fn min(const self) -> T
    fn max(const self) -> T
}

// Interface with operators
interface Arithmetic {
    fn op +(self, other: Self) -> Self
    fn op -(self, other: Self) -> Self
    fn op ==(const self, other: Self) -> bool
}

// Interface inheritance
interface Flushable {
    fn flush(self)
}

interface BufferedWriter derives Flushable {
    fn write(self, data: [byte])
    fn buffer_size(const self) -> i32
}

// Class conformance
class Renderer impl Drawable {
    fn draw(const self) -> string { return "rendering" }
    fn width(const self) -> f64 { return 100.0 }
}

struct Point {
    var x: f64
    var y: f64
}

// Struct conformance via extend
extend Point impl Drawable {
    fn draw(const self) -> string { return f"({self.x}, {self.y})" }
    fn width(const self) -> f64 { return 0.0 }
}

// Generic bound
fn <T impl Drawable> total_width(items: [T;]) -> f64 {
    var total = 0.0
    for item in items {
        total += item.width()
    }
    return total
}
```
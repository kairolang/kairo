# Interface Requirements

An interface body contains method signatures (including generic methods), static function signatures, operator signatures, constructor requirements, and [associated types](/docs/language/interfaces/#associated-types). This page covers the operator, constructor, static, `Self` and panicking requirements.

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

`Self` in an interface signature refers to the conforming type. A class that `impl Equatable` must provide `fn op ==(const self, other: Self) -> bool` where `Self` resolves to that class.

See [Operators](/docs/language/operator-overloading/) for the full list of overloadable operators.

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

A conforming type must have a constructor that matches the parameter list. The constructor name in the implementation uses the type's own name, not the interface name:

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

Only the conforming type's own constructors count; a base class's constructors do not. A type that declares no constructor at all has the implicit one (when every field can be built from nothing; see [Default Initialization](/docs/language/variables/#default-initialization)), so it satisfies a requirement with no parameters (`fn Defaultable(self)`) and nothing else. Built-in types such as `i32` and `bool` satisfy no constructor requirement, because `i32()` is not a call in Kairo; use `x as i32` to convert.

Inside a generic body, `T(args)` constructs a `T` when one of `T`'s bounds has a constructor requirement taking that many arguments:

```kairo
fn <T impl Defaultable> fresh() -> T {
    return T()
}
```

### Lifecycle attributes on constructor requirements

Constructor requirements can carry `@copy` or `@move` attributes to require a specific lifecycle category. This is how you express "T must be copyable" or "T must be movable" as an interface bound:

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

A `@copy` requirement is satisfied only by COPY types. A `@move` requirement is satisfied by COPY and MOVE types; a copy is a valid move. NON_TRANSFER types satisfy neither.

Keep lifecycle requirements separate from a default constructor requirement. Putting `fn Copyable(self)` in `Copyable` would make "copyable" also mean "default-constructible", and the bound would reject every copyable type without a default constructor. Require default construction separately, with `Defaultable` above, where a body needs it.

The standard library will provide canonical lifecycle interfaces; these are just examples. See [Lifecycle Categories](/docs/language/classes-lifecycle/#lifecycle-categories) for the underlying model.

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

Interface methods can use `Self` as a return type. `Self` resolves to the conforming type a class that `impl Chainable` and returns `Self` returns its own type:

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

Kairo has no user-visible reference types [Tether](/docs/language/tether/) infers reference semantics where needed. In practice this means `Self` returns enable fluent chaining without `->` or explicit dereferencing:

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

To return a [pointer](/docs/language/pointers/) to the conforming type, use `*Self`:

```kairo
interface Duplicable {
    fn clone(self) -> *Self
}
```

---

## Panicking Requirements

A requirement that may [panic](/docs/language/panic/) must declare its panic set, `panic(E1, E2)`. A bare `panic` on a requirement is an error: a requirement has no body to infer a set from, and the set is the contract every conformer is held to.

```kairo
struct ReadError {
    var path: string
    fn op panic (const self) -> string { return f"cannot read {self.path}" }
}

interface Source {
    fn read(self, path: string) panic(ReadError) -> string
}

class Disk impl Source {
    fn read(self, path: string) panic -> string {     // set inferred: ReadError
        if !exists(path) { panic ReadError { path: path } }
        return load(path)
    }
}

class Memory impl Source {
    fn read(self, path: string) -> string { return "" }   // ok: no panic at all
}
```

A conforming method may infer its set, but the set must be a subset of the requirement's. Panicking with a type outside it is an error at the conformer.

A generic interface's requirement may name the interface's own type parameters in its set. A conformer is held to it at the arguments it conforms to, and a [generic body](/docs/language/panic/#generic-functions) calling it through a bound panics with it at the bound's arguments:

```kairo
interface <E> Source {
    fn read(self) panic(E) -> i32
}

class File impl Source<IOError> {
    fn read(self) panic(IOError) -> i32 { ... }        // ok: E = IOError
}

fn <T impl Source<IOError>> twice(src: T) panic -> i32 {   // panics with IOError
    return src.read() + src.read()
}
```

---

## See also

- [Interfaces](/docs/language/interfaces/)
- [Operator Overloading](/docs/language/operator-overloading/)
- [Classes: Lifecycle](/docs/language/classes-lifecycle/)
- [Generics](/docs/language/generics/)
- [Tether](/docs/language/tether/)

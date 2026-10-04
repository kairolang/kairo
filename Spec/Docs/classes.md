# Classes

Classes are Kairo's primary mechanism for encapsulating state and behavior. The object model layout,
vtables, ABI follows the platform's C++ convention. The surface syntax is cleaner, `self` is always
explicit, and the copy/move model is expressed through attributes rather than reference qualifiers.

---

## Declaration

```kairo
class Foo {
    var x: i32
    var y: f64

    fn Foo(self, x: i32, y: f64) {
        self.x = x
        self.y = y
    }

    fn sum(self) -> f64 {
        return self.x as f64 + self.y
    }
}

var obj = Foo(10, 3.14)
obj.sum()   // 13.14
```

Members are declared with `var`, `const`, `static`, or `eval` inside the class body. Methods are declared
with `fn` and take `self` as the first parameter for instance methods. Omitting `self` requires the
`static` modifier. If `self` is present, it is an instance method; if not, it must be `static`.

---

## `self` and `Self`

`self` is the instance parameter. It behaves like a reference to the current object use `self.member` to
access fields and `self` to pass the object to other functions. `self` is not a pointer; you cannot
perform pointer arithmetic on it or reassign it.

### Members always need a qualifier

Unlike C++, Kairo has no implicit `this->`. Inside a function body a member of the enclosing type is not in
unqualified scope: an instance member is reached through `self`, a static member through `Self::` (or the
type's own name). A bare name is a local, a parameter, or something from an enclosing scope, and never a
member:

```kairo
class Counter {
    var hits: i32
    static total: i32 = 0

    fn Counter(self) { self.hits = 0 }

    fn bump(self) {
        self.hits += 1        // ok
        Self::total += 1      // ok (`Counter::total` works too)
        // hits += 1          // error: use of member 'hits' requires an explicit qualifier
        // total += 1         // error: use of static member 'total' requires an explicit qualifier
    }
}
```

The one exception is a name that denotes a **scope** rather than a value nested types, type aliases, and
nested modules. Naming a type is not an access through an object, so it needs no qualifier:

```kairo
class Tree {
    struct Node { var value: i32 }
    type Depth = i32

    fn root(self) -> Depth {
        var n = Node { value: 0 }   // ok: `Node` means `Self::Node`
        var d: Depth = 0            // ok: alias, same rule
        return d
    }
}
```

The rule does not depend on where a method is written. It is identical in a `class`, `struct`, `union` or
`interface` body, in an [`extend`](/docs/language/extends) block, in an out-of-line `fn Type::method`
definition, and inside a closure in any of those.

`Self` (capitalized) is a type alias for the enclosing class. In a generic class `class <T> Foo`, `Self`
resolves to `Foo<T>`. Use `Self` in parameter types, return types, and anywhere you need the class's own
type without spelling out generic arguments:

```kairo
class <T> Container {
    var items: [T]

    fn Container(self) {
        self.items = []
    }

    fn merge(self, other: Self) -> Self {
        var result = Container<T>()
        for item in self.items {
            result.items.push(item)
        }
        for item in other.items {
            result.items.push(item)
        }
        return result
    }
}
```

`Self` always refers to a reference to the class type. For a pointer, use `*Self` or `*ClassName`. The
bare class name works anywhere `Self` does `Self` is syntactic sugar, not a distinct type.

---

## Visibility

Visibility modifiers control access to members from outside the class:

| Keyword | Scope |
|---|---|
| `pub` | Accessible from any module |
| `priv` | Accessible only within the defining class or module |
| `prot` | Accessible within the defining class, subclasses, and the defining module |

Modifiers are applied per-declaration. There are no visibility blocks (`public:` sections).

### Default visibility

| Member kind | Default |
|---|---|
| Instance / static / const / eval variables | `priv` |
| Methods, constructors, destructors | `pub` |
| Operator overloads | `pub` |
| Static methods | `pub` |
| Nested types | `pub` |

```kairo
class Account {
    var balance: f64                  // priv by default
    pub var owner: string             // explicitly public

    fn Account(self, owner: string) { // pub by default
        self.owner = owner
        self.balance = 0.0
    }

    pub fn deposit(self, amount: f64) {
        self.balance += amount
    }

    priv fn audit_log(self) {
        // internal only
    }
}
```

Visibility also applies at the top level a `priv class` is only accessible within its file, a `prot
class` within its module and subclasses. See [Modules](/docs/language/modules) for how top-level
visibility interacts with imports.

> [!NOTE]
> Kairo has no `friend` keyword. If external code needs access to internals, expose it through a public
> method or adjust module-level visibility. `priv` at the top level restricts access to the current file,
> which covers most factory and serialization patterns.

---

## Constructors

Constructors use the class name as the function name and take `self` as the first parameter:

```kairo
class Point {
    var x: f64
    var y: f64

    fn Point(self, x: f64, y: f64) {
        self.x = x
        self.y = y
    }
}

var p = Point(1.0, 2.0)
```

Constructors support all the features of regular functions default parameters, named arguments,
overloading by parameter types, generic type parameters. See [Functions](/docs/language/functions).

### Const members in constructors

Class-level `const` members can be initialized in the constructor body. They get exactly one assignment;
after construction, they are frozen:

```kairo
class Config {
    const MAX_RETRIES: i32
    var timeout: f64

    fn Config(self, retries: i32, timeout: f64) {
        self.MAX_RETRIES = retries   // one-shot assignment, legal
        self.timeout = timeout
    }
}

var cfg = Config(3, 30.0)
// cfg.MAX_RETRIES = 5   // compile error: MAX_RETRIES is const
```

If a `const` member has an initializer at the declaration site, it cannot be reassigned in the constructor.

### Default and deleted constructors

```kairo
class Defaults {
    var x: i32

    fn Defaults(self) = default    // compiler-generated default constructor
}

class NoDefault {
    var x: i32

    fn NoDefault(self) = delete    // no default construction allowed
}

var a = Defaults()     // ok: x is zero-initialized
var b = NoDefault()    // compile error: default constructor is deleted
```

See [Variables](/docs/language/variables#default-initialization) for default initialization rules.

---

## Destructors - Delete Operators

Destructors use the `op delete` operator syntax:

```kairo
class Resource {
    var handle: unsafe *void

    fn Resource(self, h: unsafe *void) {
        self.handle = h
    }

    fn op delete(self) {
        release_handle(self.handle)
    }
}
```

Destructors can be defaulted or deleted:

```kairo
fn op delete(self) = default   // compiler-generated, memberwise destroy in reverse declaration order
fn op delete(self) = delete    // prevent destruction (and therefore stack allocation)
```

Destructors automatically run at the end of the enclosing scope in reverse declaration order. The delete operator can also be called explicitly to clean up a resource before the end of the scope - the recommended design pattern is to make the delete operator idempotent and safe to call multiple times:

```kairo
class Resource {
    var handle: unsafe *void

    fn Resource(self, h: unsafe *void) {
        self.handle = h
    }

    fn set_new_handle(self, h: unsafe *void) {
        self.handle = h
    }

    fn op delete(self) {
        if self.handle != &null {
            release_handle(self.handle)
            self.handle = &null
        }
    }
}

var r = Resource(open_handle())
delete r   // explicit cleanup
r.set_new_handle(open_handle())   // safe: previous handle was released
delete r   // safe: idempotent delete operator
```

---

## Lifecycle Categories

Every class has a lifecycle category that determines how its instances can be transferred between
variables. The category is implied by which transfer constructor the class defines.

### Attribute syntax

`@copy` and `@move` are attributes attached to a constructor. The convention is one attribute per line
above the declaration:

```kairo
@copy
fn Buffer(self, const other: Self) = default
```

Inline placement (`@copy fn Buffer(self, const other: Self) = default`) is permitted but discouraged. See
[Attributes](/docs/language/attributes) for the full attribute syntax.

### The transfer constructor

The **transfer constructor** governs how instances of the class are passed by value. It is written in
exactly one of two forms, with the marker on the constructor and the parameter otherwise bare:

| Form | Meaning | C++ |
|---|---|---|
| `@copy fn X(self, const other: Self)` | the usual copy | `X(const X&)` |
| `@move fn X(self, other: Self)` | move | `X(X&&)` |

```kairo
class Buffer {
    @copy
    fn Buffer(self, const other: Self) = default
}

class UniqueFile {
    @move
    fn UniqueFile(self, other: Self) = default
}
```

`@copy` without `const` (`@copy fn X(self, other: Self)`, C++ `X(X&)`) is allowed, but it cannot copy from a
`const` object or from a temporary. `@move` cannot take `const`: a move leaves its source empty.

Any other constructor that takes `Self` first and defaults every later parameter is a compile error
(SC110E):

```kairo
class X {
    fn X(self, other: Self) { }                 // error: no marker
    fn X(self, @move other: Self) { }           // error: a mode on the parameter is not a marker
    fn X(self, other: Self, k: i32 = 0) { }     // error: a defaulted extra parameter
    @move fn X(self, const other: Self) { }     // error: @move cannot take const
}
```

A constructor that takes `Self` first and then a parameter **without** a default is an ordinary
constructor:

```kairo
class X {
    fn X(self, other: Self, extra: i32) { }     // ok: not a transfer constructor
}
```

A move is written bare at the call site, `X(h)`, with no marker on the argument.

A class with no transfer constructor at all is implicitly **COPY** with all four special members
compiler-generated.

A class cannot define both `@copy` and `@move` transfer constructors pick one:

```kairo
class Bad {
    @copy fn Bad(self, const other: Self) = default
    @move fn Bad(self, other: Self) = default   // compile error
}
```

The one exception is both being `= delete`, which is the **NON_TRANSFER** form.

### The four categories

| Category | Trigger | Semantics |
|---|---|---|
| **COPY** | `@copy` ctor (explicit or implicit) | Allows copy; Tether may silently elide a copy into a move when the source is unused after the transfer |
| **MOVE** | `@move` ctor | Allows move only; copying is a compile error |
| **NON_TRANSFER** | both `@copy` and `@move` are `= delete`d | Stack-only; cannot be assigned, copied, or moved |
| **DEFAULT** | no transfer ctor declared | Treated as COPY with compiler-generated members |

A NON_TRANSFER class is the canonical scope guard:

```kairo
class ScopeLock {
    fn ScopeLock(self) = default

    @copy
    fn ScopeLock(self, const other: Self) = delete

    @move
    fn ScopeLock(self, other: Self) = delete

    fn op delete(self) { /* ... */ }
}
```

### The Rule of Three

The user writes at most three special members:

1. The default constructor (`fn Class(self)`)
2. **One** transfer constructor (`@copy` or `@move`, never both)
3. The destructor (`fn op delete(self)`)

Each may have a user body, `= default`, or `= delete`. Anything not written is compiler-generated.

```kairo
class Buffer {
    var data: unsafe *u8
    var size: usize

    fn Buffer(self, size: usize) {
        self.data = std::alloc<u8>(size)
        self.size = size
    }

    @move
    fn Buffer(self, other: Self) {
        self.data  = other.data
        self.size  = other.size
        other.data = null
        other.size = 0
    }

    fn op delete(self) {
        std::free(self.data)
    }
}
```

### Assignment is auto-derived

`op =` is generated from the transfer constructor the user does not write it. Writing it explicitly is a
compile error.

| Transfer ctor form | Generated `op =` |
|---|---|
| `= default` | `= default` |
| `= delete` | `= delete` |
| `{ body }` | destroys `self`, then runs the ctor body, then returns `self` |

The body case handles self-assignment by destroying the current state before reconstructing it.

This implies a consistency rule: if the transfer ctor has a body and `op delete` is `= delete`d, the class fails to compile the auto-derived `op =` needs to invoke the destructor and cannot. Fix by providing a destructor or by changing the transfer ctor to `= default` / `= delete`.

### Defaulted moves of non-movable members

`= default` on a `@move` ctor performs memberwise move: each member is moved through its own `@move` ctor. If a member is COPY-only (no `@move` available), that member is **copied** as part of the move matching C++ semantics. This is silent and almost always what you want; if a member must be moved or nothing, write the transfer ctor body explicitly and let the compiler error on the COPY-only field.

### Implicit-copy-with-custom-destructor warning

A class with a custom destructor but no explicit `@copy` or `@move` transfer constructor compiles, but emits a warning. The class is implicitly copyable, and a custom destructor almost always means the class owns a resource silent copies of that resource cause double-free and aliasing bugs.

```kairo
class UniqueFile {
    var handle: unsafe *void

    fn op delete(self) { close_file(self.handle) }
    // warning: custom destructor with implicit copy constructor
    //   help: declare as @move:
    //           @move fn UniqueFile(self, other: Self) = default
    //   help: or explicitly delete copy:
    //           @copy fn UniqueFile(self, const other: Self) = delete
}
```

### Tether copy elision

For COPY classes, [Tether](/docs/language/tether) may emit a move instead of a copy when it proves the source is unused after the transfer. This is a pure optimization with no observable semantic difference the source is destroyed either way, just earlier when elided. Tether does not elide if the move constructor is
deleted. Users do not opt into or out of this optimization.

---

## Inheritance

Classes inherit from other classes using `derives`:

```kairo
class Animal {
    var name: string

    fn Animal(self, name: string) {
        self.name = name
    }

    fn speak(self) {
        std::println(f"{self.name} makes a sound")
    }
}

class Dog derives Animal {
    var breed: string

    fn Dog(self, name: string, breed: string) {
        Animal::Animal(self, name)   // call base constructor
        self.breed = breed
    }

    fn speak(self) {
        std::println(f"{self.name} barks")
    }
}
```

### Inheritance visibility

By default, inheritance is public. Append `pub`, `prot`, or `priv` after `derives` to control how base
members are exposed in the derived class:

```kairo
class Derived derives pub Base { ... }    // base members keep their visibility
class Derived derives prot Base { ... }   // all base members become protected
class Derived derives priv Base { ... }   // all base members become private
```

### Multiple inheritance

```kairo
class Serializable {
    fn serialize(self) -> [byte] { ... }
}

class Printable {
    fn print(self) { ... }
}

class Document derives Serializable, Printable {
    // inherits both serialize() and print()
}

class Widget derives pub Drawable, prot EventHandler { ... }
```

### Calling base class methods

There is no `super` keyword. Call base methods explicitly using the qualified name:

```kairo
class Derived derives Base {
    fn method(self) {
        Base::method(self)
    }
}
```

### Destructors and inheritance

A class with a non-trivial destructor — its own `op delete`, or any field or base that has one — may only
derive from a class whose destructor is `virtual`. Otherwise deleting the derived object through a `*Base`
runs only the base's destructor and leaks the rest. This is a compile error at the derived class.

```kairo
class Base { fn op delete(self) { } }
class Derived derives Base {          // error: 'Base' has no virtual destructor
    fn op delete(self) { }
}
```

```kairo
class Base { virtual fn op delete(self) { } }
class Derived derives Base {          // ok
    override fn op delete(self) { }
}
```

A destructor is virtual when declared `virtual` or `override`, or when any base's is — as with any other
method, virtualness is inherited. A derived class with a trivial destructor is exempt.

### Diamond and virtual inheritance

If `B` and `C` both derive from `A`, and `D` derives from both `B` and `C`, then `D` contains two copies
of `A`'s subobject. Disambiguate with qualified names:

```kairo
class A {
    fn method(self) { std::println("A") }
}

class B derives A { fn method(self) { std::println("B") } }
class C derives A { fn method(self) { std::println("C") } }

class D derives B, C {
    fn method(self) {
        B::method(self)
        C::method(self)
    }
}
```

To share a single `A` subobject, use `derives virtual`. The most-derived class is responsible for
initializing the virtual base directly; intermediate classes' calls to the virtual base constructor are
ignored:

```kairo
class A {
    var value: i32
    fn A(self, v: i32) { self.value = v }
}

class B derives virtual A {
    fn B(self, v: i32) { A::A(self, v) }
}

class C derives virtual A {
    fn C(self, v: i32) { A::A(self, v) }
}

class D derives B, C {
    fn D(self, v: i32) {
        A::A(self, v)    // D initializes the virtual base
        B::B(self, v)
        C::C(self, v)
    }
}
```

### Lifecycle category matching

A derived class's lifecycle category must be compatible with its base's:

| Base category | Allowed derived categories |
|---|---|
| COPY | COPY, NON_TRANSFER |
| MOVE | MOVE, NON_TRANSFER |
| NON_TRANSFER | NON_TRANSFER |

A copyable base with a move-only derived class is a compile error slicing a derived instance through a
base pointer would otherwise silently copy the base subobject of a class that promised never to be
copied.

See [Casting](/docs/language/casting) for upcasting and downcasting.

---

## Virtual Dispatch

By default, methods are statically dispatched. To enable dynamic dispatch via a vtable, mark the method
`virtual` in the base class:

```kairo
class Shape {
    virtual fn area(const self) -> f64 {
        return 0.0
    }
}

class Circle derives Shape {
    var radius: f64

    fn Circle(self, radius: f64) {
        self.radius = radius
    }

    override fn area(const self) -> f64 {
        return 3.14159 * self.radius * self.radius
    }
}

var shape: *Shape = &Circle(5.0)
shape->area()   // 78.539... dynamic dispatch
```

`virtual` creates a vtable slot. `override` in the derived class replaces the entry in that slot. A class
only has a vtable pointer (8 bytes at offset 0) if it declares or inherits at least one `virtual` method.
Non-polymorphic classes have no vtable overhead.

### Abstract classes (pure virtual)

A method declared with `= virtual` has no body and must be overridden by any non-abstract derived class:

```kairo
class Shape {
    fn area(const self) -> f64 = virtual
    fn perimeter(const self) -> f64 = virtual
}

class Circle derives Shape {
    var radius: f64

    fn Circle(self, radius: f64) { self.radius = radius }

    override fn area(const self) -> f64 {
        return 3.14159 * self.radius * self.radius
    }

    override fn perimeter(const self) -> f64 {
        return 2.0 * 3.14159 * self.radius
    }
}

// var s = Shape()   // compile error: Shape has pure virtual methods
var c = Circle(5.0)  // ok: all pure virtuals overridden
```

`= virtual` implies vtable participation no `virtual` prefix is needed on the declaration. A class with
any `= virtual` method cannot be instantiated directly.

### Final

`final` prevents further overriding of a method or derivation from a class:

```kairo
final class Singleton { /* ... */ }

// class Derived derives Singleton { }   // compile error

class Base {
    virtual fn process(self) { ... }
}

class Middle derives Base {
    final override fn process(self) { ... }   // overrides, then locks
}

class Bottom derives Middle {
    // override fn process(self) { ... }   // compile error: final in Middle
}
```

---

## Interfaces

A class can declare interface conformance with `impl`. The compiler verifies at declaration time that the
class satisfies all interface requirements:

```kairo
interface Hashable {
    fn hash(const self) -> u64
}

class UserId impl Hashable {
    var id: u64

    fn UserId(self, id: u64) {
        self.id = id
    }

    fn hash(const self) -> u64 {
        return self.id
    }
}
```

Interface conformance is structural a class that has the required methods satisfies the interface
whether or not `impl` is declared. The `impl` keyword triggers the check at the declaration site rather
than at the point of use.

```kairo
class Point {
    var x: f64
    var y: f64

    fn hash(const self) -> u64 { ... }
}

fn <T impl Hashable> insert(set: {T}, item: T) { ... }

insert(my_set, Point(1.0, 2.0))   // compiles: Point has hash()
```

See [Interfaces](/docs/language/interfaces) and [Requires Clauses](/docs/language/requires).

---

## Generic Classes

Type parameters are declared in angle brackets before the class name:

```kairo
class <T> Stack {
    var items: [T]

    fn Stack(self) {
        self.items = []
    }

    fn push(self, item: T) {
        self.items.push(item)
    }

    fn pop(self) panic -> T {
        if self.items.length() == 0 {
            panic std::Error::Runtime("stack underflow")
        }
        return self.items.pop()
    }
}

var s = Stack<i32>()
s.push(42)
```

Generic classes can inherit from other generic classes:

```kairo
class <T> Base {
    var data: T
}

class <T> Derived derives Base<T> {
    var extra: i32
}
```

### Type parameter constraints

By default, a type parameter accepts any `T`. Whether a specific `T` is valid for a given instantiation
depends on what the body does with it by-reference use accepts anything, copying requires a COPY type,
moving requires COPY or MOVE, returning by value requires COPY or MOVE. Instantiation errors point at
both the body operation that required the capability and the type that lacks it.

Explicit bounds document intent and fail fast at the constraint check rather than mid-body. Two kinds of
bounds exist:

**Kind bounds** restrict `T` to a specific category of type declaration:

```kairo
fn <T: class>  process(item: T)   { ... }
fn <T: struct> serialize(item: T) { ... }
fn <T: enum>   stringify(item: T) { ... }
fn <T: union>  inspect(item: T)   { ... }
```

**Interface bounds** restrict `T` to types that satisfy a given interface. The standard library will
provide interfaces describing lifecycle capabilities, allowing constraints like "T must be copyable" or
"T must be movable" to be written as interface bounds. The exact names and shapes of these interfaces are
still being finalized in `std` write your own if you need them now:

```kairo
interface Copyable {
    fn Copyable(self)               // default ctor

    @copy
    fn Copyable(self, const other: Self)
}

fn <T impl Copyable> store(item: T) -> T { ... }
```

See [Requires Clauses](/docs/language/requires) for the full constraint system.

---

## Static Members

Static members belong to the class, not to any instance. They are declared with `static` and accessed via
`ClassName::member`:

```kairo
class Counter {
    static var count: i32 = 0

    fn Counter(self) {
        Counter::count += 1
    }

    static fn get_count() -> i32 {
        return Counter::count
    }
}

var a = Counter()
var b = Counter()
Counter::get_count()   // 2
```

Static variables require an explicit type annotation. They can be initialized at the declaration site or
at program startup. Static methods do not take `self` and cannot access instance members.

---

## Const Methods

A method that takes `const self` promises not to modify the object (except `mutable` members). It is
the ["can I change the pointee?"](/docs/language/variables#the-const-binding-rule) question asked
about the receiver. Only `const` methods can be called through a `*const T` pointer or on a `const`
binding:

```kairo hints
class Sensor {
    var reading: f64
    mutable var read_count: i32

    fn value(const self) -> f64 {
        self.read_count += 1   // ok: mutable member
        return self.reading
    }

    fn calibrate(self, offset: f64) {
        self.reading += offset
    }
}

const sensor: *const Sensor = &some_sensor
sensor->value()        // ok: const method
// sensor->calibrate(1.0)  // compile error: not const
```

`const` and non-`const` methods with the same name and parameter types cannot coexist use distinct names like `get()` and `get_mut()`. See [Variables](/docs/language/variables#the-const-binding-rule).

### Mutable members

The `mutable` qualifier allows a member to be modified even through a `const` reference or in a `const`
method:

```kairo
class Cache {
    var data: [i32]
    mutable var hit_count: i32

    fn Cache(self) {
        self.data = []
        self.hit_count = 0
    }

    fn lookup(const self, index: i32) -> i32 {
        self.hit_count += 1   // ok: mutable
        return self.data[index]
    }
}
```

`mutable` is only valid on instance variables inside class and struct bodies. It cannot appear on
top-level variables, local variables, or `const`/`eval`/`static` declarations.

> [!WARNING]
> `mutable` breaks the semantic guarantee that `const` methods do not modify the object. Use it sparingly
> caching, reference counting, and lazy initialization are the canonical use cases. If you find
> yourself marking many members `mutable`, reconsider the `const` boundary.

---

## `inline` Methods

`inline` puts the body in the interface: importers compile it themselves. Use it for small functions on
hot paths, and for functions the C++ compiler calls on your behalf (coroutine promises and awaiters).

```kairo
pub class Gate {
    pub var open: bool
    pub inline fn is_open(self) -> bool { return self.open }
}
```

Every module that uses `Gate` compiles `is_open` itself, so a call to it can be inlined there. Every
`inline` method of a class goes with the class, whether or not Kairo code calls it, because the C++
compiler may call methods Kairo never sees (`await_ready`, `initial_suspend`, ...). The class definition
itself is unchanged: the bodies are emitted after it, outside it. See [Functions](/docs/language/functions#inline)
for the rules.

`inline` is allowed on `virtual` and `override` methods. If every virtual method of a class is `inline`, the
class has no key function, so its vtable is emitted in every object that uses the class. That is correct;
it costs only size.

---

## Nested Classes

Classes can be declared inside other classes. Nested classes can access private members of the enclosing
class:

```kairo
class Tree {
    priv class Node {
        var value: i32
        var left: unsafe *Node
        var right: unsafe *Node
    }

    var root: unsafe *Node

    fn Tree(self) {
        self.root = null
    }
}
```

---

## Forward Declarations and Out-of-Line Definitions

A class can be forward-declared without a body sufficient for `*Class` uses, not for `sizeof` or member
access:

```kairo
class Parser

class Lexer {
    var parser: unsafe *Parser   // ok: pointer to incomplete type
}

class Parser {
    var lexer: Lexer
    // full definition
}
```

Member methods can also be declared inside the class body without a body and defined out-of-line using
the `Class::method` qualified-name syntax:

```kairo
class Parser {
    var tokens: [Token]
    var pos: usize

    pub fn Parser(self, tokens: [Token])
    pub fn advance(self) -> Token
    pub fn peek(const self) -> Token
    priv fn error(self, msg: string) panic
}

fn Parser::Parser(self, tokens: [Token]) {
    self.tokens = tokens
    self.pos = 0
}

fn Parser::advance(self) -> Token {
    var t = self.tokens[self.pos]
    self.pos += 1
    return t
}

fn Parser::peek(const self) -> Token = self.tokens[self.pos]

fn Parser::error(self, msg: string) panic {
    panic std::Error::Parse(msg, self.pos)
}
```

This pattern keeps the class body small and readable as an API surface, with implementation details
defined separately.

### Rules

- The qualified definition's signature must exactly match the in-class declaration: parameter types,
  return type, and all function modifiers (`const`, `unsafe`, `panic`, `eval`, `async`, `inline`,
  `final`, `virtual`, `override`, `static`).
- **Visibility is omitted** from the out-of-line definition it is taken from the in-class declaration.
  Writing `pub fn Parser::advance` is a compile error.
- **Default arguments** must appear on the in-class declaration, not the out-of-line definition.
- Parameter names may differ between declaration and definition; the definition's names are used in the
  body.

### Generic classes

For generic classes, the type parameters are re-declared on the out-of-line definition and the class
name carries its generic arguments:

```kairo
class <T> Vec {
    var data: unsafe *T
    var len: usize
    var cap: usize

    pub fn push(self, value: T)
    pub fn get(const self, i: usize) -> T
}

fn <T> Vec<T>::push(self, value: T) {
    if self.len == self.cap { self.grow() }
    self.data[self.len] = value
    self.len += 1
}

fn <T> Vec<T>::get(const self, i: usize) -> T = self.data[i]
```

### Operators, constructors, destructors

Operator overloads, constructors, and destructors follow the same pattern:

```kairo
class Vec2 {
    var x: f64
    var y: f64

    pub fn Vec2(self, x: f64, y: f64)
    pub fn op delete(self)
    pub fn op +(self, other: Vec2) -> Vec2
}

fn Vec2::Vec2(self, x: f64, y: f64) {
    self.x = x
    self.y = y
}

fn Vec2::op delete(self) { /* ... */ }

fn Vec2::op +(self, other: Vec2) -> Vec2 = Vec2(self.x + other.x, self.y + other.y)
```

### Nested types

For methods on a nested type, chain the qualifiers:

```kairo
fn Outer::Inner::method(self) { /* ... */ }
```

---

## Operator Overloading

Operators are overloaded with `fn op` syntax inside the class body:

```kairo
class Vec2 {
    var x: f64
    var y: f64

    fn Vec2(self, x: f64, y: f64) {
        self.x = x
        self.y = y
    }

    fn op +(self, other: Vec2) -> Vec2 {
        return Vec2(self.x + other.x, self.y + other.y)
    }

    fn op ==(const self, other: Vec2) -> bool {
        return self.x == other.x && self.y == other.y
    }
}

var a = Vec2(1.0, 2.0)
var b = Vec2(3.0, 4.0)
var c = a + b   // Vec2(4.0, 6.0)
```

Special operators beyond arithmetic:

| Syntax | Purpose |
|---|---|
| `fn op delete(self)` | Destructor |
| `fn op as(self) -> TargetType` | Custom type conversion via `as` |
| `fn <T> op await(self, obj: std::forward<T>) -> T` | Custom awaitable |

`op =` is **not** user-definable it is auto-derived from the transfer constructor. See
[Lifecycle Categories](#lifecycle-categories).

See [Operators](/docs/language/operators#operator-overloading) for the full list of overloadable
operators and restrictions.

---

## Memory Layout and Allocation

Class layout follows the platform's C++ ABI:

- **Non-polymorphic classes**: members laid out in declaration order with standard padding and alignment.
- **Polymorphic classes** (at least one `virtual` method): vtable pointer at offset 0 (8 bytes on 64-bit),
  followed by members.
- **Inheritance**: base class subobject precedes derived members.

Layout can be controlled with attributes:

```kairo
@packed
class Compact {
    var a: u8    // offset 0
    var b: u32   // offset 1 (no padding)
}

@align(16)
class Aligned {
    var data: [u8; 12]
}
```

A plain `var` declaration allocates on the stack:

```kairo
var obj = Foo(42)   // stack-allocated
```

Heap allocation uses `@create T()`, which returns a pointer. [Tether](/docs/language/tether) determines
whether the returned pointer is raw or promoted to a smart pointer based on usage analysis:

```kairo
var ptr = @create Foo(42)
```

See [Pointers](/docs/language/pointers) and [Tether](/docs/language/tether).

---

## Structs vs Classes

Structs and classes are distinct types:

| | Class | Struct |
|---|---|---|
| Member default visibility | `priv` for variables | `pub` for all members |
| Methods in body | Yes | No (use [extends](/docs/language/extends)) |
| Aggregate initialization | No (must use constructor) | Yes (`Foo { field: value }`) |
| Inheritance | `derives` | Not supported |
| Virtual dispatch | Yes | No |
| Lifecycle categories | Yes | N/A (no transfer constructors; copyable whenever every field is) |

See [Structures](/docs/language/structures).

---

## Summary

```kairo
// Basic class
class Point {
    var x: f64
    var y: f64

    fn Point(self, x: f64, y: f64) {
        self.x = x
        self.y = y
    }

    fn distance(const self, other: Self) -> f64 {
        var dx = self.x - other.x
        var dy = self.y - other.y
        return std::sqrt(dx * dx + dy * dy)
    }
}

// Move-only class
class UniqueFile {
    var handle: unsafe *void

    fn UniqueFile(self, path: string) {
        self.handle = open_file(path)
    }

    @move
    fn UniqueFile(self, other: Self) {
        self.handle  = other.handle
        other.handle = null
    }

    fn op delete(self) {
        close_file(self.handle)
    }
}

// Inheritance with virtual dispatch
class Shape {
    fn area(const self) -> f64 = virtual
}

class Circle derives Shape {
    var radius: f64

    fn Circle(self, r: f64) { self.radius = r }

    override fn area(const self) -> f64 {
        return 3.14159 * self.radius * self.radius
    }
}

// Generic class with interface conformance
class <T impl Comparable> PriorityQueue impl Iterable {
    priv var heap: [T]

    fn PriorityQueue(self) { self.heap = [] }
    fn push(self, item: T) { ... }
    fn pop(self) panic -> T { ... }
}

// Final class
final class Immutable {
    const value: i32

    fn Immutable(self, v: i32) { self.value = v }
}
```

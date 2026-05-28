# Classes

Classes are Kairo's primary mechanism for encapsulating state and behavior. They follow C++ semantics closely
-- same object layout, same vtable rules, same ABI with a cleaner declaration syntax and a few deliberate
restrictions (no `const` overloading, no `friend`, explicit `self`).

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
with `fn` and always take `self` as the first parameter for instance methods. Omitting `self` requires the
`static` modifier. There is no ambiguity if `self` is present, it is an instance method; if not, it
must be `static`.

---

## `self` and `Self`

`self` is the instance parameter. It behaves like a reference to the current object you use `self.member`
to access fields and `self` to pass the object to other functions. `self` is not a pointer; you cannot
perform pointer arithmetic on it or reassign it.

`Self` (capitalized) is a type alias for the enclosing class. In a generic class `class <T> Foo { ... }`,
`Self` resolves to `Foo<T>`. Use `Self` in parameter types, return types, and anywhere you need to refer to
the class's own type without spelling out generic arguments:

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

`Self` always means a reference to the class type. For a pointer, use `*Self` or `*ClassName`. The bare
class name (`Foo`, `Container<T>`) also works anywhere `Self` does `Self` is syntactic sugar, not a
distinct type.

---

## Visibility

Visibility modifiers control access to members from outside the class:

| Keyword | Scope |
|---|---|
| `pub` | Accessible from any module |
| `priv` | Accessible only within the defining class or module |
| `prot` | Accessible within the defining class, subclasses, and the defining module |

Modifiers are applied per-declaration. There are no visibility blocks (`public:` sections) like in C++.

### Default visibility

| Member kind | Default |
|---|---|
| Instance / static / const / eval variables | `priv` |
| Methods, constructors, destructors | `pub` |
| Operator overloads | `pub` |
| Static methods | `pub` |
| Nested types (classes, enums, structs) | `pub` |

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

Visibility also applies at the top level. A `priv class` is only accessible within its file; a `prot class`
is accessible within its module and subclasses. See [Modules](/docs/language/modules) for how top-level
visibility interacts with imports.

> [!NOTE]
> Kairo has no `friend` keyword. If external code needs access to internals, expose it through a public
> method or adjust module-level visibility. `priv` at the top level restricts access to the current file,
> which covers most factory and serialization patterns without a `friend` escape hatch.

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

Constructors support all the same features as regular functions default parameters, named arguments,
overloading by parameter types, and generic type parameters. See [Functions](/docs/language/functions) for
the full parameter syntax.

### `const` members in constructors

Class-level `const` members can be initialized in the constructor body. They get exactly one assignment 
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

## Destructors

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
fn op delete(self) = default   // compiler-generated
fn op delete(self) = delete    // prevent destruction (and therefore stack allocation)
```

Destructors run at the end of the enclosing scope in reverse declaration order, identical to C++.

---

## The Rule of Five

If a class defines none of the five special operations, the compiler generates all of them:

```kairo
class Implicit {
    var data: i32
}

// Compiler generates:
// fn Implicit(self) = default                              default constructor
// fn op delete(self) = default                             destructor
// fn Implicit(self, other: Self) = default                 copy constructor
// fn op =(self, other: Self) -> Self = default             copy assignment
// fn Implicit(self, other: mref!(Self)) = default          move constructor
// fn op =(self, other: mref!(Self)) -> Self = default      move assignment
```

If the user defines any one of these, the remaining four are still compiler-generated unless explicitly
`= delete`d. This differs from C++ where defining certain special members suppresses others Kairo always
generates what you do not provide.

`mref!(Self)` is a compiler intrinsic that produces an rvalue reference (equivalent to C++'s `&&`). Kairo
does not expose `&&T` as general-purpose syntax `mref!()` is the escape hatch for move semantics.
See [Ownership](/docs/language/ownership) for the full move model.

> [!NOTE]
> The special member syntax is under consideration for revision. The current `op =` and constructor-based
> approach mirrors C++ directly, but a more explicit naming scheme (`op copy`, `op move`) may replace it
> in a future language revision. The semantics will remain identical.

---

## `mutable` Members

The `mutable` qualifier allows a member to be modified even through a `const` reference or in a `const`
method. This is identical to C++'s `mutable` keyword:

```kairo
class Cache {
    var data: [i32]
    mutable var hit_count: i32

    fn Cache(self) {
        self.data = []
        self.hit_count = 0
    }

    fn lookup(const self, index: i32) -> i32 {
        self.hit_count += 1   // ok: hit_count is mutable
        return self.data[index]
    }
}
```

`mutable` is only valid on instance variables inside class and struct bodies. It cannot appear on top-level
variables, local variables, or `const`/`eval`/`static` declarations.

> [!WARNING]
> `mutable` breaks the semantic guarantee that `const` methods do not modify the object. Use it sparingly
> caching, reference counting, and lazy initialization are the canonical use cases. If you find yourself
> marking many members `mutable`, reconsider the `const` boundary.

---

## Inheritance

Classes inherit from other classes using the `derives` keyword:

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
class members are exposed in the derived class:

```kairo
class Derived derives pub Base { ... }    // base members keep their visibility
class Derived derives prot Base { ... }   // all base members become protected
class Derived derives priv Base { ... }   // all base members become private
```

This matches C++ inheritance visibility semantics exactly.

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
```

Per-base visibility works with multiple inheritance:

```kairo
class Widget derives pub Drawable, prot EventHandler { ... }
```

### Calling base class methods

There is no `super` keyword. Call base class methods explicitly using the qualified name:

```kairo
class Derived derives Base {
    fn method(self) {
        Base::method(self)   // call Base's implementation
        // ... additional logic
    }
}
```

### Diamond inheritance

Diamond inheritance behaves identically to C++ if `B` and `C` both derive from `A`, and `D` derives
from both `B` and `C`, then `D` contains two copies of `A`'s subobject. Disambiguate with qualified names:

```kairo
class A {
    fn method(self) { std::println("A") }
}

class B derives A {
    fn method(self) { std::println("B") }
}

class C derives A {
    fn method(self) { std::println("C") }
}

class D derives B, C {
    fn method(self) {
        B::method(self)   // calls B's version
        C::method(self)   // calls C's version
    }
}
```

Virtual inheritance is also supported to share a single `A` subobject between `B` and `C` see below.

```kairo
// Virtual inheritance single shared A subobject
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
        A::A(self, v)    // D must initialize the virtual base directly
        B::B(self, v)
        C::C(self, v)
    }
}

var d = D(42)
// d.value is unambiguous only one A subobject exists
```

To share a single `A` subobject instead of getting two copies, use `derives virtual`. The most-derived class (`D`) is responsible for initializing the virtual base directly intermediate classes' calls to the virtual base constructor are ignored, identical to C++ virtual inheritance.
[Casting](/docs/language/casting) for upcasting and downcasting across inheritance hierarchies.

---

## Virtual Dispatch

By default, methods are statically dispatched. To enable dynamic dispatch via a vtable, mark the method
`virtual` in the base class:

```kairo
class Shape {
    virtual fn area(self) const -> f64 {
        return 0.0
    }
}

class Circle derives Shape {
    var radius: f64

    fn Circle(self, radius: f64) {
        self.radius = radius
    }

    override fn area(self) const -> f64 {
        return 3.14159 * self.radius * self.radius
    }
}

var shape: *Shape = &Circle(5.0)
shape->area()   // 78.539... dynamic dispatch calls Circle::area
```

`virtual` on the base class method creates a vtable slot. `override` in the derived class replaces
the entry in that slot. Both keywords behave identically to their C++ counterparts.

A class only has a vtable pointer (8 bytes at offset 0) if it declares or inherits at least one `virtual`
method. Non-polymorphic classes have no vtable overhead.

### Abstract classes (pure virtual)

A method declared with `= virtual` has no body and must be overridden by any non-abstract derived class:

```kairo
class Shape {
    fn area(self) const -> f64 = virtual    // pure virtual
    fn perimeter(self) const -> f64 = virtual
}

class Circle derives Shape {
    var radius: f64

    fn Circle(self, radius: f64) {
        self.radius = radius
    }

    override fn area(self) const -> f64 {
        return 3.14159 * self.radius * self.radius
    }

    override fn perimeter(self) const -> f64 {
        return 2.0 * 3.14159 * self.radius
    }
}

// var s = Shape()   // compile error: Shape has pure virtual methods
var c = Circle(5.0)  // ok: all pure virtuals are overridden
```

`= virtual` implies vtable participation no `virtual` prefix is needed on the declaration. A class with
any `= virtual` method cannot be instantiated directly.

---

## `final`

`final` prevents further overriding of a method or derivation from a class:

```kairo
final class Singleton {
    // ...
}

// class Derived derives Singleton { }   // compile error: Singleton is final

class Base {
    virtual fn process(self) { ... }
}

class Middle derives Base {
    final override fn process(self) { ... }   // overrides, then locks
}

class Bottom derives Middle {
    // override fn process(self) { ... }   // compile error: process is final in Middle
}
```

`final` on a method can be combined with `override`. `final` on a class prevents any inheritance.

---

## Interfaces

A class can declare interface conformance with `impl`. The compiler verifies at declaration time that the
class satisfies all interface requirements:

```kairo
interface Hashable {
    fn hash(self) const -> u64
}

class UserId impl Hashable {
    var id: u64

    fn UserId(self, id: u64) {
        self.id = id
    }

    fn hash(self) const -> u64 {
        return self.id
    }
}
```

Interface conformance is structural a class that has the required methods satisfies the interface
whether or not `impl` is declared. The `impl` keyword triggers an explicit check at the declaration site.
Without it, the check happens at the point of use (e.g., when the class is passed to a generic function
with an `impl` bound).

```kairo
class Point {
    var x: f64
    var y: f64

    fn hash(self) const -> u64 { ... }
}

fn <T impl Hashable> insert(set: {T}, item: T) { ... }

insert(my_set, Point(1.0, 2.0))   // compiles: Point has hash(), satisfies Hashable
```

See [Interfaces](/docs/language/interfaces) for interface declarations, default methods, and
[Bounds](/docs/language/bounds) for generic constraint syntax.

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
        if self.items.len() == 0 {
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

Constrain type parameters with `impl` or `derives` bounds:

```kairo
class <T impl Comparable> SortedList {
    var items: [T]

    fn insert(self, item: T) {
        // can use comparison operators on T
    }
}
```

See [Functions](/docs/language/functions#generic-functions) for generic syntax and
[Bounds](/docs/language/bounds) for the full constraint system.

---

## Static Members

Static members belong to the class, not to any instance. They are declared with `static` and accessed
via `ClassName::member`:

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

Static variables require an explicit type annotation. They can be initialized at the declaration site
(as above) or left for program-startup initialization, following the same rules as C++ static members.

Static methods do not take `self` and cannot access instance members.

---

## `const` Methods

A method that takes `const self` promises not to modify the object (except `mutable` members). Only
`const` methods can be called through a `*const T` pointer or on a `const` binding:

```kairo
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
// sensor->calibrate(1.0)  // compile error: calibrate is not const
```

`const` and non-`const` methods with the same name and parameter types cannot coexist use distinct
names like `get()` and `get_mut()`. See [Variables](/docs/language/variables#the-const-binding-rule) for
the full `const` model.

---

## Nested Classes

Classes can be declared inside other classes. Nested classes can access private members of the enclosing
class, matching C++ behavior:

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

## Forward Declarations

A class can be forward-declared without a body for use in situations where the full definition is not yet
available typically for mutual references or when the implementation is in a separate translation unit:

```kairo
class Parser    // forward declaration enough for *Parser, not for sizeof or member access

class Lexer {
    var parser: unsafe *Parser   // ok: pointer to incomplete type
}

class Parser {
    var lexer: Lexer
    // full definition
}
```

A class can also be forward-declared with member signatures but no method bodies:

```kairo
class Parser {
    var lexer: Lexer

    fn parse(self) -> Expr       // signature only
    fn next_token(self) -> Token // signature only
}

fn Parser::parse(self) -> Expr {
    // body defined outside the class
}

fn Parser::next_token(self) -> Token {
    // body defined outside the class
}
```

Out-of-class definitions must exactly match the forward-declared signature parameter types, return type,
and all modifiers. Default parameter values belong in the forward declaration, not the out-of-class
definition.

---

## Operator Overloading

Operators are overloaded with the `fn op` syntax inside the class body:

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

    fn op ==(self, other: Vec2) const -> bool {
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
| `fn op as(self) -> TargetType` | Custom type conversion via `as` keyword |
| `fn <T> op await(self, obj: std::forward<T>) -> T` | Custom awaitable (e.g., futures) |

See [Operators](/docs/language/operators#operator-overloading) for the full list of overloadable operators
and restrictions.

---

## Memory Layout

Class layout follows the platform's C++ ABI:

- **Non-polymorphic classes:** members laid out in declaration order with standard padding and alignment
  rules, identical to C++ struct layout.
- **Polymorphic classes** (at least one `virtual` method): vtable pointer at offset 0 (8 bytes on 64-bit),
  followed by members.
- **Inheritance:** base class subobject precedes derived members, matching C++ layout.

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

### Allocation

Classes follow C++ allocation rules. A plain `var` declaration allocates on the stack:

```kairo
var obj = Foo(42)   // stack-allocated
```

Heap allocation uses `std::create<T>()`, which returns a pointer. [AMT](/docs/language/amt) determines
whether the returned pointer is raw or promoted to a smart pointer based on usage analysis:

```kairo
var ptr = std::create<Foo>(42)   // heap-allocated, AMT chooses pointer type
```

See [Pointers](/docs/language/pointers) for pointer types and [AMT](/docs/language/amt) for the
full allocation and lifetime model.

---

## Structs vs Classes

Structs and classes are distinct types in Kairo:

| | Class | Struct |
|---|---|---|
| Member default visibility | `priv` for variables | `pub` for all members |
| Methods in body | Yes | No (use [extends](/docs/language/extends)) |
| Aggregate initialization | No (must use constructor) | Yes (`Foo { field: value }`) |
| Inheritance | `derives` | Not supported |
| Virtual dispatch | Yes | No |

See [Structures](/docs/language/structures) for struct declarations and semantics.

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

// Inheritance with virtual dispatch
class Shape {
    fn area(self) const -> f64 = virtual
}

class Circle derives Shape {
    var radius: f64

    fn Circle(self, r: f64) { self.radius = r }

    override fn area(self) const -> f64 {
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

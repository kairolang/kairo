# Classes

Classes are Kairo's primary mechanism for encapsulating state and behavior. The object model layout,
vtables, ABI follows the platform's C++ convention. The surface syntax is cleaner, `self` is always
explicit, and the copy/move model is expressed through [attributes](/docs/language/attributes/) rather than reference qualifiers.

## In this section

- [Class Lifecycle](/docs/language/classes-lifecycle/): destructors and lifecycle categories
- [Inheritance and Virtual Dispatch](/docs/language/classes-inheritance/): `derives`, `virtual`, abstract classes and `final`
- [Forward Declarations and Out-of-Line Definitions](/docs/language/classes-out-of-line/)
- [Generics](/docs/language/generics/): type parameter constraints

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
`interface` body, in an [`extend`](/docs/language/extends/) block, in an out-of-line `fn Type::method`
definition, and inside a [closure](/docs/language/closures/) in any of those.

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
class` within its module and subclasses. See [Modules](/docs/language/modules/) for how top-level
visibility interacts with [imports](/docs/language/imports/).

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
overloading by parameter types, generic type parameters. See [Functions](/docs/language/functions/).

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

See [Variables](/docs/language/variables/#default-initialization) for default initialization rules.

---

Destructors are covered in [Destructors - Delete Operators](/docs/language/classes-lifecycle/#destructors---delete-operators).

Lifecycle categories are covered in [Lifecycle Categories](/docs/language/classes-lifecycle/#lifecycle-categories).

Inheritance and virtual dispatch are covered in [Inheritance and Virtual Dispatch](/docs/language/classes-inheritance/).

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

See [Interfaces](/docs/language/interfaces/) and [Requires Clauses](/docs/language/requires/).

---

## Generic Classes

[Type parameters](/docs/language/generics/) are declared in angle brackets before the class name:

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

Type parameter constraints are covered in [Generics](/docs/language/generics/#type-parameter-constraints).

---

## Static Members

Static members belong to the class, not to any instance. They are declared with `static` and accessed via
`ClassName::member`:

```kairo
class Counter {
    static count: i32 = 0

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

Static variables are declared `static name: Type`, with no `var`, and require an explicit type
annotation. They can be initialized at the declaration site or at program startup. Static methods do
not take `self` and cannot access instance members.

> [!NOTE]
> Static fields do not compile yet: an initializer on one is rejected, and without one the program does
> not link. See [Status](/docs/status/#not-compiled-yet).

---

## Const Methods

A method that takes `const self` promises not to modify the object (except `mutable` members). It is
the ["can I change the pointee?"](/docs/language/variables/#the-const-binding-rule) question asked
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

`const` and non-`const` methods with the same name and parameter types cannot coexist use distinct names like `get()` and `get_mut()`. See [Variables](/docs/language/variables/#the-const-binding-rule).

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
itself is unchanged: the bodies are emitted after it, outside it. See [Functions](/docs/language/functions-declarations/#inline)
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

Forward declarations and out-of-line definitions are covered in [Forward Declarations and Out-of-Line Definitions](/docs/language/classes-out-of-line/).

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
[Lifecycle Categories](/docs/language/classes-lifecycle/#lifecycle-categories).

See [Operators](/docs/language/operator-overloading/) for the full list of overloadable
operators and restrictions.

---

## Memory Layout and Allocation

Class layout follows the platform's C++ ABI:

- **Non-polymorphic classes**: members laid out in declaration order with standard padding and alignment.
- **Polymorphic classes** (at least one `virtual` method): vtable pointer at offset 0 (8 bytes on 64-bit),
  followed by members.
- **Inheritance**: base class subobject precedes derived members.

Layout can be controlled with [attributes](/docs/language/attributes/):

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

Heap allocation uses `@create T()`, which returns a pointer. [Tether](/docs/language/tether/) determines
whether the returned pointer is raw or promoted to a smart pointer based on usage analysis:

```kairo
var ptr = @create Foo(42)
```

See [Pointers](/docs/language/pointers/) and [Tether](/docs/language/tether/).

---

## Structs vs Classes

Structs and classes are distinct types:

| | Class | Struct |
|---|---|---|
| Member default visibility | `priv` for variables | `pub` for all members |
| Methods in body | Yes | No (use [extends](/docs/language/extends/)) |
| Aggregate initialization | Only if the class declares no constructor | Yes (`Foo { field: value }`) |
| Inheritance | `derives` | Not supported |
| Virtual dispatch | Yes | No |
| Lifecycle categories | Yes | N/A (no transfer constructors; copyable whenever every field is) |

See [Structures](/docs/language/structures/).

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

---

## See also

- [Structures](/docs/language/structures/)
- [Interfaces](/docs/language/interfaces/)
- [Operator Overloading](/docs/language/operator-overloading/)
- [Extends](/docs/language/extends/)
- [Generics](/docs/language/generics/)
- [Pointers](/docs/language/pointers/)
- [Tether](/docs/language/tether/)

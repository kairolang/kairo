# Classes

Classes are Kairo's primary mechanism for encapsulating state and behavior. The object model layout, vtables, ABI follows the platform's C++ convention. The surface syntax is cleaner, `self` is always explicit, and the copy/move model is expressed through [attributes](/docs/language/attributes/) rather than reference qualifiers.

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

Members are declared with `var`, `const`, `static`, `eval`, or `thread` inside the class body. Methods are declared with `fn` and take `self` as the first parameter for instance methods. Omitting `self` requires the `static` modifier. If `self` is present, it is an instance method; if not, it must be `static`.

---

## `self` and `Self`

`self` is the instance parameter. It behaves like a reference to the current object use `self.member` to access fields and `self` to pass the object to other functions. `self` is not a pointer; you cannot perform pointer arithmetic on it or reassign it.

### Members always need a qualifier

Unlike C++, Kairo has no implicit `this->`. Inside a function body a member of the enclosing type is not in unqualified scope: an instance member is reached through `self`, a static member through `Self::` (or the type's own name). A bare name is a local, a parameter, or something from an enclosing scope, and never a member:

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

The one exception is a name that denotes a **scope** rather than a value nested types, type aliases, and nested modules. Naming a type is not an access through an object, so a qualifier is not required. Prefer `Self::Node` anyway: a bare nested type, type alias or associated type of the enclosing type compiles, but the compiler warns and offers a fix-it that inserts `Self::`, because nothing at the use says the name is a member rather than something from the module:

```kairo
class Tree {
    struct Node { var value: i32 }
    type Depth = i32

    fn root(self) -> Self::Depth {
        var n = Self::Node { value: 0 }   // preferred
        var m = Node { value: 1 }         // ok, but warns: write `Self::Node`
        var d: Depth = 0                  // ok, but warns: alias, same rule
        return d
    }
}
```

The warning applies anywhere in the body, a field type or method signature included. It names the innermost type only: inside `Node`, a bare `Depth` (a member of `Tree`, not of `Node`) and `Node` itself are not warned, since `Self::` there would mean `Node::`.

The rule does not depend on where a method is written. It is identical in a `class`, `struct`, `union` or `interface` body, in an [`extend`](/docs/language/extends/) block, in an out-of-line `fn Type::method` definition, and inside a [closure](/docs/language/closures/) in any of those.

`Self` (capitalized) is a type alias for the enclosing class. In a generic class `class <T> Foo`, `Self` resolves to `Foo<T>`. Use `Self` in parameter types, return types, and anywhere you need the class's own type without spelling out generic arguments:

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

`Self` always refers to a reference to the class type. For a pointer, use `*Self` or `*ClassName`. The bare class name works anywhere `Self` does `Self` is syntactic sugar, not a distinct type.

---

## Visibility

Visibility modifiers control access to members from outside the class:

| Keyword | Scope |
|---|---|
| `pub` | Accessible from any module |
| `priv` | Accessible within the defining class, and anywhere in the file that declares it, free functions included |
| `prot` | What `priv` allows, plus every class that derives from the defining class, in any module |

Modifiers are applied per-declaration. There are no visibility blocks (`public:` sections).

Kairo checks visibility itself: using a `priv` member from another file, or a `prot` one outside a subclass, is an error that offers to make the member `pub`. Operators are members like any other: a `priv fn op +` is usable only where a `priv` method would be. A base's members reached through a `derives priv` (or `derives prot`) edge are private (protected) to the deriving class and its file.

A subclass in another file uses a `prot` member the way C++ allows a protected one:

- an instance field or method only through an object of the subclass's own type, or of a type deriving from it (`self.hits`, `other_counter.hits`), not through a `*Base` or a sibling subclass;
- a `prot` constructor only as the base initializer `Base::Base(self, ...)` at the start of its own constructor, not to build a separate `Base`.

`prot` statics and nested types have no such restriction.

The C++ that Kairo generates keeps these levels: a `priv` member is `private:` and a `prot` one `protected:`, and the class names its file's functions and types as friends. A C++ program that includes the module sees the members as Kairo has them (see [What crosses an include](/docs/language/c-cpp-exposing/#what-crosses-an-include)).

### Default visibility

| Member kind | Default |
|---|---|
| Instance / static / const / eval / thread variables | `priv` |
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

Visibility also applies at the top level a `priv class` is only accessible within its file, a `prot class` within its module and subclasses. See [Modules](/docs/language/modules/) for how top-level visibility interacts with [imports](/docs/language/imports/).

> [!NOTE]
> Kairo has no `friend` keyword. If external code needs access to internals, expose it through a public method or adjust module-level visibility. `priv` at the top level restricts access to the current file, which covers most factory and serialization patterns.

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

Constructors support all the features of regular functions default parameters, named arguments, overloading by parameter types, generic type parameters. See [Functions](/docs/language/functions/).

### Const members in constructors

Class-level `const` members can be initialized in the constructor body. They get exactly one assignment; after construction, they are frozen:

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

### Fields without a default

A field with no initializer whose type has no default value (`bool`, an [enum with payloads](/docs/language/enums-adt/), a class with no default constructor, or an array of any of these; see [Variables](/docs/language/variables/#default-initialization)) must be initialized by every constructor, like a `const` member. The constructor's first write of the whole field is its initialization; later writes are ordinary assignments:

```kairo
enum Frame {
    Burst { base: i32, count: i32 },
    Idle,
}

class Batch {
    var frames: [Frame; 3]
    var ready: bool

    fn Batch(self, base: i32) {
        self.frames = [.Burst { base: base, count: 3 }, .Idle, .Idle]  // initialization
        self.ready = false
        self.log()                                                      // the object exists from here
        self.frames[2] = .Burst { base: 1, count: 1 }                  // ordinary assignment
    }

    fn log(self) { }
}
```

Until every such field is initialized, the object does not exist yet, so the constructor can use `self` only to initialize fields and to read the ones already initialized: no method call, no `return`. A field the constructor leaves uninitialized on some path is an error at the constructor.

An array field can also be built element by element: writing every element once, `self.frames[k] = ...` for each `k` from `0` to `N - 1` with a constant index, initializes it. The writes may come in any order and be spread over branches, as long as every path writes every element exactly once, outside any loop, before the array (or `self`) is read. Each element is built where its write is, so the right-hand sides run in source order with the statements around them. From the last element on, the array exists and further element writes are ordinary assignments:

```kairo
class Pair {
    var frames: [Frame; 2]

    fn Pair(self, base: i32) {
        self.frames[1] = .Idle                              // builds element 1
        self.frames[0] = .Burst { base: base, count: 2 }    // builds element 0: frames exists from here
        self.frames[1] = .Burst { base: 1, count: 1 }      // ordinary assignment
    }
}
```

Leaving an element out on some path, writing one twice, an index that is not a constant, a write inside a loop, or reading the array before its last element is an error naming the elements still missing or the offending write. Only whole elements count: a write into an element (`self.toks[0].n = 1`) needs the element to exist already, and an array of arrays cannot be built element by element; assign those whole.

Giving the field an initializer at its declaration (`var frames: [Frame; 3] = [.Idle, .Idle, .Idle]`) lifts the requirement.

An array is not assignable, so an array field's one whole write in a constructor is its initialization: it must happen on every path through the constructor or on none, and never in a loop. A second whole write is an error; write the elements instead.

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

A class can declare interface conformance with `impl`. The compiler verifies at declaration time that the class satisfies all interface requirements:

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

Interface conformance is structural a class that has the required methods satisfies the interface whether or not `impl` is declared. The `impl` keyword triggers the check at the declaration site rather than at the point of use.

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
struct StackUnderflow {
    fn op panic (const self) -> string { return "stack underflow" }
}

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
            panic StackUnderflow {}
        }
        return self.items.pop()
    }
}

var s = Stack<i32>()
s.push(42)
```

> [!NOTE]
> A `panic` method of a generic class, like `pop` here, is not supported yet ([SC116E](/docs/language/diagnostics/#sc116e-a-feature-is-not-yet-supported)): a generic body's panic set will be inferred per instantiation. See [Status](/docs/status/#not-compiled-yet).

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

Static members belong to the class, not to any instance. They are declared with `static` and accessed via `ClassName::member`:

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

Static variables are declared `static name: Type`, with no `var`, and require an explicit type annotation. They can be initialized at the declaration site or at program startup. Static methods do not take `self` and cannot access instance members.

---

## Const Methods

A method that takes `const self` promises not to modify the object (except `mutable` members). It is the ["can I change the pointee?"](/docs/language/variables/#the-const-binding-rule) question asked about the receiver. Only `const` methods can be called through a `*const T` pointer or on a `const` binding:

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

The `mutable` qualifier allows a member to be modified even through a `const` reference or in a `const` method:

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

`mutable` is only valid on instance variables inside class and struct bodies. It cannot appear on top-level variables, local variables, or `const`/`eval`/`static` declarations.

> [!WARNING]
> `mutable` breaks the semantic guarantee that `const` methods do not modify the object. Use it sparingly caching, reference counting, and lazy initialization are the canonical use cases. If you find yourself marking many members `mutable`, reconsider the `const` boundary.

---

## `inline` Methods

`inline` puts the body in the interface: importers compile it themselves. Use it for small functions on hot paths, and for functions the C++ compiler calls on your behalf (coroutine promises and awaiters).

```kairo
pub class Gate {
    pub var open: bool
    pub inline fn is_open(self) -> bool { return self.open }
}
```

Every module that uses `Gate` compiles `is_open` itself, so a call to it can be inlined there. Every `inline` method of a class goes with the class, whether or not Kairo code calls it, because the C++ compiler may call methods Kairo never sees (`await_ready`, `initial_suspend`, ...). The class definition itself is unchanged: the bodies are emitted after it, outside it. See [Functions](/docs/language/functions-declarations/#inline) for the rules.

`inline` is allowed on `virtual` and `override` methods. If every virtual method of a class is `inline`, the class has no key function, so its vtable is emitted in every object that uses the class. That is correct; it costs only size.

---

## Nested Classes

Classes can be declared inside other classes. Nested classes can access private members of the enclosing class:

```kairo
class Tree {
    priv class Node {
        var value: i32
        var left: unsafe *Node
        var right: unsafe *Node
    }

    var root: unsafe *Node

    fn Tree(self) {
        self.root = &null
    }
}
```

A type nested in a generic class belongs to each instance: `L<i32>::P` and `L<f64>::P` are different types, and a member of `L<i32>::P` typed with `L`'s parameter reads with `i32`. Name it through the instance from outside the class (`var q: L<i32>::P = l.make(7)`, `L<i32>::P { k: 1 }`, `L<i32>::Color::Red`); inside the class, `Self::P` is the current instance's. A generic function can take one and deduce the instance's arguments from it (`fn <T> first(r: L<T>::P) -> T`).

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

`op =` is **not** user-definable it is auto-derived from the transfer constructor. See [Lifecycle Categories](/docs/language/classes-lifecycle/#lifecycle-categories).

See [Operators](/docs/language/operator-overloading/) for the full list of overloadable operators and restrictions.

---

## Memory Layout and Allocation

Class layout follows the platform's C++ ABI:

- **Non-polymorphic classes**: members laid out in declaration order with standard padding and alignment.
- **Polymorphic classes** (at least one `virtual` method): vtable pointer at offset 0 (8 bytes on 64-bit), followed by members.
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

Heap allocation uses `@create T()`, which returns a pointer. [Tether](/docs/language/tether/) determines whether the returned pointer is raw or promoted to a smart pointer based on usage analysis:

```kairo
var *ptr = @create Foo(42)
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
        other.handle = &null
    }

    fn op delete(self) {
        close_file(self.handle)
    }
}

// Inheritance with virtual dispatch
class Shape {
    virtual fn area(const self) -> f64
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
    fn pop(self) panic -> T { ... }   // `panic` in a generic class: not supported yet (SC116E)
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

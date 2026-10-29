# Inheritance and Virtual Dispatch

Classes inherit from other classes using `derives`, and opt into dynamic dispatch with `virtual`.

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

A base initializer is a statement of its own among the **first** statements of the constructor, before anything else runs: it builds the base part of `self` before any field. Its first argument is `self`; the other arguments may not use `self` (the object does not exist yet). Each base is initialized at most once, and only a direct base, or a [virtual base](#diamond-and-virtual-inheritance), can be. Calling a constructor by name anywhere else is an error: to build a value, call the type (`Animal("Rex")`).

A base with no default constructor (its constructors all take arguments, or its default constructor is `= delete`) must be initialized by every constructor of a class that derives from it, so such a derived class has to declare a constructor. Declaring only a transfer constructor (`@copy` / `@move`), even a deleted one, removes the implicit default constructor; declare `fn X(self) = default` to keep it.

A derived class's own `@copy` or `@move` constructor initializes its base with the base's transfer constructor: `Base::Base(self, other)` transfers the base part of `other`.

### Inheritance visibility

By default, inheritance is public. Append `pub`, `prot`, or `priv` after `derives` to control how base members are exposed in the derived class:

```kairo
class Derived derives pub Base { ... }    // base members keep their visibility
class Derived derives prot Base { ... }   // all base members become protected
class Derived derives priv Base { ... }   // all base members become private
```

The narrowing applies to members reached through `Derived`. The conversion from `*Derived` to `*Base` stays available everywhere, and through a `*Base` the members have their own visibility again. (In the generated C++ the base is public and the members are narrowed with `private:` / `protected:` using-declarations, so a C++ program sees the same thing.)

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

The qualified call is not virtual: `Base::method(self)` runs `Base`'s version even when `method` is `virtual` and overridden further down. A derived method with the same parameters (and the same `const self` or plain `self`) overrides or hides the base's, so `d.method()` on a derived value calls the derived one; a base overload with different parameters stays callable on the derived value (Kairo merges the overload sets, as C++ does with a `using` declaration). A C++ class keeps C++'s lookup: a name it declares hides the base's unless its definition says `using Base::name;`.

### Protected members from another file

A subclass declared in a different file than its base reaches a `prot` instance member only through an object of its own type or a type deriving from it, and calls a `prot` constructor only as its base initializer:

```kairo
class Counter derives Base {
    fn Counter(self) { Base::Base(self, 2) }       // ok: base initializer
    fn own(self) -> i32 { return self.hits }        // ok
    fn other(self, c: *Counter) -> i32 { return c->hits }   // ok
    fn via_base(self, b: *Base) -> i32 { return b->hits }   // error: through a Base
    fn standalone(self) { var b = Base(5) }        // error: a separate Base
}
```

Code in the base's own file has no such restriction.

### Destructors and inheritance

A class with a non-trivial destructor (its own `op delete` with a body, or any field or base that has one) may only derive from a class whose destructor is `virtual`. Otherwise deleting the derived object through a `*Base` runs only the base's destructor and leaks the rest. This is a compile error at the derived class.

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

A destructor is virtual when declared `virtual` or `override`, or when any base's is. As with any other method, virtualness is inherited. A derived class with a trivial destructor is exempt.

### Diamond and virtual inheritance

If `B` and `C` both derive from `A`, and `D` derives from both `B` and `C`, then `D` contains two copies of `A`'s subobject. Disambiguate with qualified names:

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

To share a single `A` subobject, use `derives virtual`. The most-derived class is responsible for initializing the virtual base directly; intermediate classes' calls to the virtual base constructor are ignored:

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

A derived class's [lifecycle category](/docs/language/classes-lifecycle/#lifecycle-categories) must be compatible with its base's:

| Base category | Allowed derived categories |
|---|---|
| COPY | COPY, NON_TRANSFER |
| MOVE | MOVE, NON_TRANSFER |
| NON_TRANSFER | NON_TRANSFER |

A copyable base with a move-only derived class is a compile error slicing a derived instance through a base pointer would otherwise silently copy the base subobject of a class that promised never to be copied.

See [Casting](/docs/language/casting/) for upcasting and downcasting.

---

## Virtual Dispatch

By default, methods are statically dispatched. To enable dynamic dispatch via a vtable, mark the method `virtual` in the base class:

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

`virtual` creates a vtable slot. `override` in the derived class replaces the entry in that slot. A class only has a vtable pointer (8 bytes at offset 0) if it declares or inherits at least one `virtual` method. Non-polymorphic classes have no vtable overhead.

A `virtual` method that may [panic](/docs/language/panic/) must declare its panic set (`virtual fn load(self) panic(IOError) -> Data`), since it is the contract for every override. An `override` may leave its own set inferred, but that set must be a subset of the base method's. See [Declared Panic Sets](/docs/language/panic/#declared-panic-sets).

### Abstract classes (pure virtual)

A `virtual` method declared with no body is pure virtual: it must be overridden by any non-abstract derived class:

```kairo
class Shape {
    virtual fn area(const self) -> f64
    virtual fn perimeter(const self) -> f64
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

A class with a pure virtual method is abstract, and so is a derived class that leaves any of its bases' pure methods unoverridden. Creating an object of an abstract class (`Shape()`, `Shape{ }`) is a compile error that points at the method keeping it abstract; a pointer to one (`*Shape`) is fine. In C++ a pure virtual method is `virtual R f() = 0`, so a C++ class can derive a Kairo abstract class and a Kairo class can derive a C++ one.

Kairo methods are `noexcept` in C++ (see [Exceptions](/docs/language/c-cpp-exceptions/#c-exceptions-through-kairo-frames)), so a C++ class overriding a Kairo `virtual fn` must declare its override `noexcept` as well, unless the Kairo method is `@unwind`:

```cpp
struct Rect : shape::Shape {                       // Shape: a Kairo abstract class
    double area() const noexcept override { return w * h; }
};
```

Only a `virtual` method without a body is pure; a method that is not `virtual` and has no body is a declaration. After `=`, a function takes only an expression, `default` or `delete`: the old spelling `fn area(const self) -> f64 = virtual` is an error whose fix-it rewrites it to `virtual fn area(const self) -> f64`.

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

## See also

- [Classes](/docs/language/classes/)
- [Memory Layout and Allocation](/docs/language/classes/#memory-layout-and-allocation)
- [Class Lifecycle](/docs/language/classes-lifecycle/)
- [Forward Declarations and Out-of-Line Definitions](/docs/language/classes-out-of-line/)
- [Interfaces](/docs/language/interfaces/)
- [Casting](/docs/language/casting/)

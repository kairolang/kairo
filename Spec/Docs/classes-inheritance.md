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

### Inheritance visibility

By default, inheritance is public. Append `pub`, `prot`, or `priv` after `derives` to control how base members are exposed in the derived class:

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

`= virtual` implies vtable participation no `virtual` prefix is needed on the declaration. A class with any `= virtual` method cannot be instantiated directly.

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

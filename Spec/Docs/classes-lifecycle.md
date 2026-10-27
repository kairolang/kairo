# Class Lifecycle

How instances of a [class](/docs/language/classes/) are destroyed, and how they are transferred between variables.

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

Destructors automatically run at the end of the enclosing scope in reverse declaration order. The delete operator can also be called explicitly to clean up a resource before the end of the scope. The recommended design is to make the delete operator idempotent: the first call runs the destructor and releases the resources the members own, and later calls have no effect, so an object can be deleted more than once without double deletion or dangling pointers:

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

### Constructors and destructors never panic

No constructor (one with parameters, the default constructor, or a transfer constructor) and no destructor can [panic](/docs/language/panic/). Marking one `panic` is a compile error, and so is a panic that would escape one: an unhandled panicking call or `panic` statement in its body, or in a field default it runs. An object is either built whole or not at all, and a destructor runs on every exit from its scope, where nothing could take an error. Handle the error inside with `try`/`catch`, or stop the program with `crash!()`. Construction that can fail belongs in a static factory function, which may panic and returns the object:

```kairo
class Conn {
    var fd: i32
    fn Conn(self, fd: i32) { self.fd = fd }
    static fn open(path: string) panic(IOError) -> Conn {
        return Conn(open_fd(path))   // open_fd may panic; the constructor never does
    }
}
```

### `delete` does not free

`delete` in kairo does not free memory. It is a **destruction operation** that runs the [destructor](/docs/language/classes-lifecycle/#destructors---delete-operators) and any side effects, but does not reclaim the allocation. Meaning if the class can be re-constructed with a separate function call, the memory is still valid and can be reused. The `delete` operation is used to explicitly clean up resources without deallocating the memory, which is useful in certain scenarios where you want to manage memory manually or reuse it.

```kairo
class MyClass {
    var data: unsafe *i32 = &null

    fn MyClass(self) = default

    fn init(self) {
        self.data = unsafe std::alloc<i32>(sizeof i32 * 10) // 10 i32's allocated
    }

    fn op delete(self) {
        if self.data != &null {
            unsafe std::free(self.data)
            self.data = &null
        }
    }
}

var obj = MyClass() // stack allocated the object itself
obj.init() // allocate the buffer data points to
// do something with obj.data
delete obj // runs obj's destructor, which frees the buffer; obj's own storage is not freed
obj.init() // obj is still valid storage and can be re-initialized
```

What `delete` frees is whatever the destructor frees: here the buffer owned by the `data` member. The object `delete` is applied to is not freed; its storage stays valid.

---

## Lifecycle Categories

Every class has a lifecycle category that determines how its instances can be transferred between variables. A class's category is what its transfer constructors leave usable. If it can be copied, it is **COPY**. If it can only be moved, it is **MOVE**. If it can be neither, it is **NON_TRANSFER**. Deleting either transfer constructor on its own makes the class NON_TRANSFER: a declared copy constructor, even a deleted one, means no move is generated, and a deleted move constructor removes the copy. The canonical form deletes both, which says so explicitly.

### Attribute syntax

`@copy` and `@move` are attributes attached to a constructor. The convention is one attribute per line above the declaration:

```kairo
@copy
fn Buffer(self, const other: Self) = default
```

Inline placement (`@copy fn Buffer(self, const other: Self) = default`) is permitted but discouraged. See [Attributes](/docs/language/attributes/) for the full attribute syntax.

### The transfer constructor

The **transfer constructor** governs how instances of the class are passed by value. It is written in exactly one of two forms, with the marker on the constructor and the parameter otherwise bare:

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

`@copy` without `const` (`@copy fn X(self, other: Self)`, C++ `X(X&)`) is allowed, but it cannot copy from a `const` object or from a temporary. `@move` cannot take `const`: a move leaves its source empty.

Any other constructor that takes `Self` first and defaults every later parameter is a compile error (SC110E):

```kairo
class X {
    fn X(self, other: Self) { }                 // error: no marker
    fn X(self, @move other: Self) { }           // error: a mode on the parameter is not a marker
    fn X(self, other: Self, k: i32 = 0) { }     // error: a defaulted extra parameter
    @move fn X(self, const other: Self) { }     // error: @move cannot take const
}
```

A constructor that takes `Self` first and then a parameter **without** a default is an ordinary constructor:

```kairo
class X {
    fn X(self, other: Self, extra: i32) { }     // ok: not a transfer constructor
}
```

A move is written bare at the call site, `X(h)`, with no marker on the argument.

A transfer constructor written `= default` copies or moves every field, which initializes each of them. One with a body is a constructor like any other: it must initialize every `const` member and every [field without a default](/docs/language/classes/#fields-without-a-default), and its first whole write of such a field is that field's initialization.

A class with no transfer constructor takes the weakest category its bases and fields allow: **COPY** if all of them are COPY, **MOVE** if any is move-only, **NON_TRANSFER** if any cannot be transferred. Its special members are compiler-generated to match.

A class cannot define both `@copy` and `@move` transfer constructors pick one:

```kairo
class Bad {
    @copy fn Bad(self, const other: Self) = default
    @move fn Bad(self, other: Self) = default   // compile error (SC057E)
}
```

The one exception is both being `= delete`, the canonical **NON_TRANSFER** form.

A class also cannot declare two transfer constructors of the same kind, such as `@copy` with and without `const` ([SC057E](/docs/language/diagnostics/#sc057e-more-than-one-transfer-constructor)).

### The four categories

| Category | Trigger | Semantics |
|---|---|---|
| **COPY** | `@copy` ctor (explicit or implicit) | Allows copy; Tether may silently elide a copy into a move when the source is unused after the transfer |
| **MOVE** | `@move` ctor | Allows move only; copying is a compile error |
| **NON_TRANSFER** | either transfer constructor `= delete` (canonically both) | Stack-only; cannot be assigned, copied, or moved |
| **DEFAULT** | no transfer ctor declared | Derived from bases and fields (see above) |

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

A `= default` member is what the compiler would have generated: it is trivial when the same member of every base and field is. A transfer constructor or destructor with a body makes the class non-trivial, and so does a deleted one or a `virtual` destructor. A polymorphic class (a `virtual` method or a virtual base) is never trivially copyable, and neither is a NON_TRANSFER class.

```kairo
class Buffer {
    var data: unsafe *u8
    var size: usize

    fn Buffer(self, size: usize) {
        self.data = unsafe std::alloc<u8>(size)
        self.size = size
    }

    @move
    fn Buffer(self, other: Self) {
        self.data  = other.data
        self.size  = other.size
        other.data = &null
        other.size = 0
    }

    fn op delete(self) {
        unsafe std::free(self.data)
    }
}
```

### Assignment is auto-derived

`op =` is generated from the transfer constructor the user does not write it. Writing it explicitly is a compile error.

| Transfer ctor form | Generated `op =` |
|---|---|
| none written | member by member, like the compiler-generated transfer constructor |
| `= default` | `= default`: member by member |
| `= delete` | `= delete` |
| `{ body }` | checks for self-assignment, destroys `self`, rebuilds it in place through the transfer constructor, returns `self` |

The body case first checks for self-assignment: `x = x` does nothing. Otherwise it destroys `self`, builds a new value in its place by running the transfer constructor on the right-hand side, and returns `self`.

Member-by-member assignment needs every base and field to be assignable. If one is not, the class has no `op =`.

A polymorphic class whose transfer constructor has a body has no `op =` either. Rebuilding it in place would give the object this class's vtable pointer, which is wrong when the object is really a derived class or is the base part of one. A polymorphic class with a `= default` transfer constructor, or with none, assigns member by member as usual.

Assigning a value whose class has no `op =` is a compile error (SC071E). When the reason is a polymorphic class whose transfer constructor has a body, the error adds: "a polymorphic class whose transfer constructor has a body cannot be assigned; construct a new value".

This implies a consistency rule: if the transfer ctor has a body and `op delete` is `= delete`d, the class fails to compile the auto-derived `op =` needs to invoke the destructor and cannot. Fix by providing a destructor or by changing the transfer ctor to `= default` / `= delete`.

### Defaulted moves of non-movable members

`= default` on a `@move` ctor performs memberwise move: each member is moved through its own `@move` ctor. If a member is COPY-only (no `@move` available), that member is **copied** as part of the move matching C++ semantics. This is silent and almost always what you want; if a member must be moved or nothing, write the transfer ctor body explicitly and let the compiler error on the COPY-only field.

The converse is checked too. A defaulted `@copy` constructor requires every base and field to be copyable, and a defaulted `@move` requires every base and field to be movable or copyable. Otherwise it is a compile error ([SC129E](/docs/language/diagnostics/#sc129e-a-defaulted-transfer-constructor-cannot-be-generated)) naming the field. A transfer constructor with a body is exempt; it decides for itself how each field is transferred.

### Implicit-copy-with-custom-destructor warning

A class with a custom destructor but no explicit `@copy` or `@move` transfer constructor compiles, but emits a warning. The class is implicitly copyable, and a custom destructor almost always means the class owns a resource silent copies of that resource cause double-free and aliasing bugs. The warning applies only when the class is actually copyable; a class that is move-only or non-transferable because of its fields does not get it.

```kairo
class UniqueFile {
    var handle: unsafe *void

    fn op delete(self) { close_file(self.handle) }
    // warning: custom destructor with implicit copy constructor
    //   help: declare as @move:
    //           @move fn UniqueFile(self, other: Self) = default
    //   help: or make it non-transferable:
    //           @copy fn UniqueFile(self, const other: Self) = delete
}
```

### Tether copy elision

For COPY classes, [Tether](/docs/language/tether/) may emit a move instead of a copy when it proves the source is unused after the transfer. This is a pure optimization with no observable semantic difference the source is destroyed either way, just earlier when elided. Tether does not elide if the move constructor is deleted. Users do not opt into or out of this optimization.

---

## See also

- [Classes](/docs/language/classes/)
- [Inheritance and Virtual Dispatch](/docs/language/classes-inheritance/)
- [Forward Declarations and Out-of-Line Definitions](/docs/language/classes-out-of-line/)
- [Ownership](/docs/language/ownership/)
- [Interface Requirements](/docs/language/interfaces-requirements/#lifecycle-attributes-on-constructor-requirements)
- [Tether](/docs/language/tether/)
- [Attributes](/docs/language/attributes/)
- [Diagnostics](/docs/language/diagnostics/)

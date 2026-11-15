# Generics

How type parameters of [generic classes](/docs/language/classes/#generic-classes) and functions are constrained.

## Type parameter constraints

A generic body may use only what its bounds grant. The body is checked once, where it is defined, against its bounds, never per instantiation. Calling a method no bound declares, copying a `T` without a copy bound, or declaring `var x: T` without a constructor bound is a compile error in the generic itself. So is an operator or a conversion on a `T` (`a == b`, `a + b`, `a as string`) that no bound declares, a null test on a `T` (only a `T?` can be null), and a `match` pattern other than a binding or `_` on a `T`. So is passing a `T` (or forwarding a pack) to a generic whose bound it does not carry: in `fn <T> fwd(x: T) = one(x)` with `fn <T impl Named> one(x: T)`, `fwd`'s `T` must be bounded by `Named` or by an interface that derives it (R051E when `T` has no bound, with a fix-it adding it; R025E when its bounds do not include one). A bound that declares the operator (`fn op ==(const self, other: Self) -> bool`) makes it a call through the bound, and a `derives` bound whose base declares it makes it a call of the base's operator. See [Generic Bodies](/docs/language/interfaces/#generic-bodies).

An f-string is the exception: a hole on a value whose type only the instantiation knows (a `T`, or a member reached through one) is formatted per instance, with the same rules as a concrete value (builtin types, strings, pointers, plain enums, `repr()`, an `op as` to `string`). An instance whose type has no way to format is an error at that instance. A format spec on such a hole (`f"{x:>4}"`) is not supported yet.

```kairo
fn <T> show(x: T) -> string { return f"value: {x}" }   // formatted per instance
show(42)        // "value: 42"
show("hi")      // "value: hi"
```

A generic type at a dependent argument is not opaque: a `match` on a `Rep<T>` names `Rep`'s variants, and `==` on two `Rep<T>` compares their variants, as for any [ADT](/docs/language/enums-adt/).

**Implicit capabilities.** Every type parameter may be destroyed and moved without saying so. Instantiating with a type whose `op finally` is `= delete`, or whose category is NON_TRANSFER, is an error at the instantiation site. It names the generic's implicit requirement, not a line inside its body. (Opt-out syntax: TBD.)

Two kinds of bounds exist:

**Kind bounds** restrict `T` to a specific category of type declaration:

```kairo
fn <T: class>  process(item: T)   { ... }
fn <T: struct> serialize(item: T) { ... }
fn <T: enum>   stringify(item: T) { ... }
fn <T: union>  inspect(item: T)   { ... }
```

An argument of another kind is an error (SC292E) where the generic is used.

A bound may be a rooted path, `fn <T impl ::m::I>`, naming the interface from the file's root.

**Interface bounds** restrict `T` to types that satisfy a given [interface](/docs/language/interfaces/). The standard library will provide interfaces describing [lifecycle capabilities](/docs/language/classes-lifecycle/#lifecycle-categories), allowing constraints like "T must be copyable" or "T must be movable" to be written as interface bounds. The exact names and shapes of these interfaces are still being finalized in `std` write your own if you need them now:

```kairo
interface Copy {
    @copy
    fn Copy(self, const other: Self)
}

interface Default {
    fn Default(self)
}

fn <T impl Copy> store(item: T) -> T { ... }
```

See [Requires Clauses](/docs/language/requires/) for the full constraint system.

### Mixins: a base that calls its derived class

A generic base can call methods of the class that derives it (the C++ CRTP pattern) when its parameter is bounded by both `derives` on the base itself and an interface that declares those methods. The `derives` bound lets the base cast `&self` down to `*X` statically, with no vtable; the `impl` bound is what lets the body call `weight()` on it:

```kairo
interface Weighted { fn weight(const self) -> i32 }

class <X derives Counter<X> impl Weighted> Counter {
    fn dyn(self) -> *X { return &self as *X }        // static downcast, no vtable
    fn bump(self) -> i32 { return self.dyn()->weight() }
}

class Node derives Counter<Node> impl Weighted {
    fn weight(const self) -> i32 { return 5 }
}
```

Without the `impl Weighted` bound, `self.dyn()->weight()` is an error in the base: the body may use only what its bounds grant. See [Casting: the CRTP downcast](/docs/language/casting/#downcasting-base-to-derived) for the cast's rules.

A failed bound on one overload of several removes that overload, like a false `requires`. A call whose overloads differ only in `requires` clauses is resolved by the bounds too; if the bounds do not decide every candidate's clause, it is SC320E.

## Value parameters

A generic parameter can be a compile-time **value** instead of a type: `eval N: T`. Its argument must be [evaluable at compile time](/docs/language/eval/), a literal, an `eval` constant, or arithmetic over them, and inside the generic `N` is a constant of type `T`, usable as an array length:

```kairo
eval CAPACITY = 16

class <eval N: usize, T> Ring {
    var items: [T; N]
    fn capacity(const self) -> usize { return N }
}

fn <eval N: usize> scaled() -> usize { return N * 2 }

var r = Ring<CAPACITY, i32>()     // the same type as Ring<16, i32>
var s = scaled<4>()               // 8
```

A function's value parameter is given explicitly (`scaled<4>()`) or deduced from an array argument's length (`fn <eval N: usize> sum(const a: [i32; N])` called with a `[i32; 3]`). A `const` binding is not evaluable at compile time, so it cannot be a value argument; `const N: T` is not a parameter spelling either (write `eval N: T`).

### Computed lengths and arguments

An array length or value argument can be computed from value parameters, `eval` constants and calls of `eval` functions:

```kairo
eval fn twice(x: usize) -> usize { return x * 2 }

class <eval N: usize> Buf {
    var data: [i32; N + 1]          // one spare slot
}

fn <eval M: usize> make() -> Buf<M * 2> { return Buf<M * 2>() }

fn table() {
    var t: [i32; twice(3)]          // six elements
}
```

Once the parameters have values the length is a number again: `Buf<3>`'s `data` is a `[i32; 4]`, the same type as any other `[i32; 4]`. A length the compiler does not compute itself, because it calls an `eval fn` or reads an `eval` constant that does, is identified by how it is written: `[i32; twice(3)]` is one type wherever it is written, but it is not `[i32; 6]`, even though `twice(3)` is 6 (as in C++, where a dependent expression is compared by its form). A computed length is not deduced: `fn <eval N: usize> f(a: [i32; N + 1])` needs `N` from somewhere else, such as `f<3>(a)`.

A computed length or argument works in any type: a local's, a field's, a parameter's or return type, a file-scope variable's (`var a: [i32; twice(2)]` as a field). The functions and constants it reads are compiled ahead of the declaration that uses them. What cannot work is a cycle: a field of `R` whose length calls an `eval fn` that itself needs `R` complete (`sizeof R`, a local `R`, a method of `R`) is an error, since `R` does not exist yet where its own field is laid out.

### Eval classes as value parameters

A value parameter can also have the type of an [eval class](/docs/language/eval/#eval-in-classes), when every field is `pub`, no field points to mutable memory, and every constructor is `eval`:

```kairo
struct Config {
    pub var size: i32
    pub var label: string
    eval fn Config(self, size: i32, label: string) {
        self.size = size
        self.label = label
    }
}

eval SMALL = Config(4, "small")

class <eval C: Config> Widget {
    fn size(const self) -> i32 { return C.size }
}

var w = Widget<SMALL>()
```

The argument is an `eval` binding of the class or a call of its `eval` constructor (`Grid<Pt(2, 3)>`, `Widget<Config(4, "small")>`, string literals included). Two arguments with the same value are the same type: `Widget<Config(4, "small")>` is `Widget<SMALL>`, because `SMALL` is that same constructor call over the same literals. A binding computed by an `eval fn` is compared by its name instead, as a computed length is. A class that breaks a rule is an error naming the first field or constructor at fault.

## Function specializations

`fn <> name<Args>(...)` replaces the body of a generic function for exactly those arguments.

```kairo
fn <T> width() -> i32 { return 1 }
fn <> width<i32>() -> i32 { return 4 }

width<u8>()    // 1
width<i32>()   // 4
```

Its signature is the primary's with the arguments substituted: the same parameter types and modes, the same return type and the same qualifiers (SC330E otherwise). It may be written in another module than its primary: `import lib::*`, then `fn <> pick<u8>() -> i32 { ... }`. Every part of the program that calls `pick<u8>()` runs it, including modules that do not import the one that defines it. Code compiled separately from that module, such as a prebuilt library or a C++ file that includes only the primary's header, does not see it. A class specialization stays in its primary's module (R042E otherwise); extend the class instead. A call always names the primary; for those arguments the specialization's body runs, in Kairo and in C++ callers. A specialization that more than one primary matches is SC330E. A specialization of a member of a generic type is not supported yet.

---

## See also

- [Generic Classes](/docs/language/classes/#generic-classes)
- [Interfaces](/docs/language/interfaces/)
- [Interface Requirements](/docs/language/interfaces-requirements/)
- [Requires Clauses](/docs/language/requires/)
- [Where Clauses](/docs/language/where/)
- [Generic Functions](/docs/language/functions/#generic-functions)
- [Generic Structs](/docs/language/structures/#generic-structs)
- [Class Lifecycle](/docs/language/classes-lifecycle/#lifecycle-categories)

A vector, set or map type can head a static path: `[i32]::with_capacity(8)` is `Vector<i32>::with_capacity(8)`, and likewise `{T}::f()` and `{K: V}::f()`.

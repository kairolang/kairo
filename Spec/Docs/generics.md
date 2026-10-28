# Generics

How type parameters of [generic classes](/docs/language/classes/#generic-classes) and functions are constrained.

## Type parameter constraints

A generic body may use only what its bounds grant. The body is checked once, where it is defined, against its bounds, never per instantiation. Calling a method no bound declares, copying a `T` without a copy bound, or declaring `var x: T` without a constructor bound is a compile error in the generic itself. So is an operator, a conversion or an interpolation on a `T` (`a == b`, `a + b`, `a as string`, `f"{a}"`) that no bound declares, a null test on a `T` (only a `T?` can be null), and a `match` pattern other than a binding or `_` on a `T`; a bound that declares the operator (`fn op ==(const self, other: Self) -> bool`) makes it a call through the bound. See [Generic Bodies](/docs/language/interfaces/#generic-bodies).

A generic type at a dependent argument is not opaque: a `match` on a `Rep<T>` names `Rep`'s variants, and `==` on two `Rep<T>` compares their variants, as for any [ADT](/docs/language/enums-adt/).

**Implicit capabilities.** Every type parameter may be destroyed and moved without saying so. Instantiating with a type whose `op delete` is `= delete`, or whose category is NON_TRANSFER, is an error at the instantiation site. It names the generic's implicit requirement, not a line inside its body. (Opt-out syntax: TBD.)

Two kinds of bounds exist:

**Kind bounds** restrict `T` to a specific category of type declaration:

```kairo
fn <T: class>  process(item: T)   { ... }
fn <T: struct> serialize(item: T) { ... }
fn <T: enum>   stringify(item: T) { ... }
fn <T: union>  inspect(item: T)   { ... }
```

**Interface bounds** restrict `T` to types that satisfy a given [interface](/docs/language/interfaces/). The standard library will provide interfaces describing [lifecycle capabilities](/docs/language/classes-lifecycle/#lifecycle-categories), allowing constraints like "T must be copyable" or "T must be movable" to be written as interface bounds. The exact names and shapes of these interfaces are still being finalized in `std` write your own if you need them now:

```kairo
interface Copyable {
    @copy
    fn Copyable(self, const other: Self)
}

interface Defaultable {
    fn Defaultable(self)
}

fn <T impl Copyable> store(item: T) -> T { ... }
```

See [Requires Clauses](/docs/language/requires/) for the full constraint system.

## The `: type` regime (transitional)

`<T: type>` opts a parameter out of the rule above. The compiler does not check the body against bounds. It types the body as written and emits it as an unconstrained C++ template, and the C++ compiler checks each instantiation. These are C++ template semantics. The regime exists so that code written for the bootstrap compiler keeps compiling while it is migrated to interface bounds. The main case is CRTP mixins that call into the class deriving from them.

It is on by default until the compiler compiles itself, since the bootstrap compiler's own code is written in it. To turn it off, build with `-fno-duck-generics`: `: type` is then an error (SC001E). If the body uses no member of `T`, the error carries a fix-it that deletes `: type`. If it does, a note points at the first member use and suggests an interface bound instead.

```kairo
// kairo main.k   (with -fno-duck-generics: error SC001E at ': type')
class <X: type> Mixin {
    fn doubled(const self) -> i32 {
        unsafe {
            var d = &self as unsafe *const X
            return d->value() * 2      // checked per instance by C++
        }
    }
}

class Seven derives Mixin<Seven> {
    fn value(const self) -> i32 { return 7 }
}
```

Limits while it lasts:

- Errors in the body are reported per instantiation, as C++ errors, at the instance that breaks. A body that is never instantiated is never checked.
- A member use is emitted exactly as written: `x.f(args)`, `p->f(args)`, `x.template f<A>(args)`, `T::f(args)`. An [extension](/docs/language/extends/) member is not a C++ member, so calling one through `T` fails in C++.
- A call the compiler knows can panic is not yet supported inside such a body (SC116E), nor is a `panic` function under a `: type` parameter. (A bounded or unbounded generic body [may panic](/docs/language/panic/#generic-functions).) A member call through `T` names no known callee, so its panics are not tracked. If it is used as a value, C++ rejects the type. If its result is discarded, the panic is dropped and only a C++ `nodiscard` warning reports it.
- Operators, `===`, null tests and `match` patterns on a value of type `T` are left to C++ as well (none of the definition-time errors above); `x as string` and `f"{x}"` on it are still rejected.

The regime and its flag will be removed once those mixins carry `<T impl Interface>` bounds. Use an interface bound in new code.

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

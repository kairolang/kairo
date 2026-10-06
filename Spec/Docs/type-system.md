# Type System

Kairo is statically typed with full type inference. Every value has a single concrete type known at compile
time. The type system is nominal two types are the same if they have the same name and generic arguments,
not if they happen to have the same structure.

---

## Type Aliases

`type` declares a transparent alias for an existing type. The alias and the original type are fully
interchangeable:

```kairo
type Byte = u8
type <T> Matrix = [[T]]
type <T> TokenVec = [T]

var b: Byte = 42        // Byte and u8 are the same type
var m: Matrix<f64> = [[1.0, 2.0], [3.0, 4.0]]
var v: TokenVec<i32> = [1, 2, 3]
```

Aliases can be generic. Type parameters are declared in angle brackets before the alias name.

### Strict aliasing mode

By default, aliases are transparent. The `-fno-type-aliasing` compiler flag makes aliases into distinct
types that require explicit construction:

```kairo
type MyString = string

// With -ftype-aliasing (default):
var a: string = "hello"
var b: MyString = a        // ok: transparent alias

// With -fno-type-aliasing:
var a: string = "hello"
var b: MyString = MyString(a) // explicit construction required
b = a                         // compile error: type mismatch
```

### Aliases cannot widen visibility

An alias introduces a second *name* for a type, not a second type. It may not be more visible than
the type it names an alias that published a `priv` type under a `pub` name would hand callers a
type its author never exported:

```kairo
priv struct Base1 {
    var x: i32
}

pub type Base2 = Base1      // compile error: pub alias names a priv type
pub type Base3 = *Base1     // so does this
priv type Base4 = Base1     // ok: no wider than its target
```

Every name the alias mentions counts, not only the outermost one. A pointer, nullable, vector, slice, set,
tuple, array, map, function-pointer parameter or return, and a generic argument all publish their
target just as directly, and so does a private module used as a path segment:

```kairo
priv module M {
    pub struct T { var a: i32 }
}

pub type Leak = M::T        // compile error: reaches T through a priv module
```

The rule applies through chains, since an alias of an alias is still a name for the same type:

```kairo
priv type Inner = Config
pub  type Outer = Inner     // compile error: Inner is priv
```

The error is reported at the alias, not at each use of it. To expose a restricted view of a private
type rather than the type itself, declare a wrapper with the members you mean to publish an alias
cannot narrow what it names.

### Restrictions

Type aliases must reference existing named types. Inline anonymous type definitions are not permitted:

```kairo
type Pair = (i32, i32)                // ok: aliases a tuple type
// type Anon = struct { var x: i32 }  // compile error: cannot alias anonymous type definitions
```

If you need a named struct, declare a struct. Type aliases are for giving new names to existing types,
not for defining new ones.

A chain of aliases may be at most 64 links deep before the compiler stops following it. Raise the
limit with `--cmax-type-alias-depth=<n>` if a generated or re-exported chain legitimately needs more.

---

## Type Inference

The compiler infers types from initializers, return expressions, and generic arguments. Explicit
annotations are optional where inference succeeds.

### Variable inference

```kairo
var x = 42              // i32
var y = 3.14            // f64
var z = "hello"         // string
var v = [1, 2, 3]       // [i32]
var p = (1.0, true)     // (f64, bool)
```

See [Primitives](/docs/language/primitives) for default literal types.

### Generic argument inference

Generic type arguments are inferred from the arguments at the call site:

```kairo
fn <T> identity(x: T) -> T { return x }

identity(42)        // T inferred as i32
identity("hello")   // T inferred as string
```

This extends to complex generic patterns:

```kairo
fn <T> first(items: [T]) -> T { return items[0] }

var nums: [i32] = [1, 2, 3]
first(nums)   // T inferred as i32 from [T] matching [i32]
```

Explicit generic arguments are required only when inference is ambiguous or when no arguments provide
type information:

```kairo
var s = Stack<i32>()   // no arguments to infer from, must specify
```

### Return type inference

Return types are never inferred for block-bodied functions or forward declarations. They must be declared
explicitly, or they default to `void`:

```kairo
fn add(a: i32, b: i32) -> i32 { return a + b }   // explicit
fn log(msg: string) { std::println(msg) }        // defaults to void
```

Expression-bodied functions (`fn foo() = expr`) are the one exception: if the return
type annotation is omitted, it is inferred from the expression.

```kairo
fn square(x: i32) = x * x          // inferred as i32
fn name() = "Kairo"                // inferred as string
fn typed(x: i32) -> i64 = x as i64 // explicit still allowed
```

See [Functions](/docs/language/functions#expression-bodied-functions)

---

## Implicit Conversions

Kairo minimizes implicit conversions. The following are the only implicit conversions in the language:

### Numeric widening

Integer and float types can be implicitly widened to a larger type of the same signedness:

```kairo
var a: i32 = 42
var b: i64 = a       // ok: i32 to i64

var x: f32 = 1.0f32
var y: f64 = x       // ok: f32 to f64
```

Narrowing conversions require an explicit `as` cast. See [Casting](/docs/language/casting).

### `T` to `T?` - Non-nullable to Nullable

A non-nullable value is implicitly convertible to its nullable counterpart:

```kairo
fn maybe_log(msg: string?) { ... }

var s = "hello"
maybe_log(s)   // string implicitly converts to string?
```

The reverse (`T?` to `T`) requires explicit unwrapping see
[Variables](/docs/language/variables#nullable-types).

### Derived-to-base pointer

A pointer to a derived class is implicitly convertible to a pointer to its base class:

```kairo
class Animal { ... }
class Dog derives Animal { ... }

fn feed(animal: *Animal) { ... }

var dog = Dog("Rex", "Labrador")
feed(&dog)   // *Dog implicitly converts to *Animal
```

This is always safe the base subobject is at a known offset. The reverse (base-to-derived) requires
an explicit cast because it can fail at runtime. See [Casting](/docs/language/casting).

### List literal to a container

A list literal takes the type its target asks for: an array `[T; N]` with a matching element count, a slice
`[T;]`, or a vector `[T]`. With no target it is an array.

```kairo
fn total(xs: [i32;]) -> i32 { ... }

total([1, 2, 3])               // the literal becomes a slice for this call
var v: [i32] = [1, 2, 3]       // the literal becomes a vector
```

This applies to the literal only. Array and vector variables convert only to a slice, below.

### Array or vector to slice

An array `[T; N]` converts to a slice `[T;]` implicitly. The slice is a view of the array; nothing is copied.
A `const` array converts only to `[const T;]`. A vector `[T]` also converts to a slice implicitly.

```kairo
fn total(xs: [i32;]) -> i32 { ... }

var a = [1, 2, 3]
total(a)                       // a viewed as [i32;]
var v: [i32] = [4, 5]
total(v)                       // v viewed as [i32;]
```

The other direction, `[T;]` to `[T]`, stays explicit because it allocates.

### `@implicit` conversion operators

A type's `op as` marked `@implicit` applies without `as` where its exact result type is wanted. See
[Implicit `op as`](/docs/language/operators#implicit-op-as).

### No other implicit conversions

The following conversions are all explicit (require `as`):

- Enum to integer or integer to enum
- `T?` to `T` (use `unwrap!()`, `??`, or null checking)
- Base-to-derived pointer (downcast)
- Any pointer to a different pointer type
- Integer narrowing or float-to-integer
- Slice to vector (`s as [T]`; it allocates)

---

## Subtyping

Kairo has a limited subtyping hierarchy:

- `!` (never type) is a subtype of every type
- A derived class is a subtype of its base class(es)

Interface-satisfying types are not subtypes of the interface. Interfaces are constraints checked at
compile time via `impl` bounds, not runtime-dispatchable types. For runtime polymorphism, use
base class pointers with [virtual dispatch](/docs/language/classes#virtual-dispatch) or
`unsafe *void` for type-erased pointers.

---

## The Never Type (`!`)

`!` is the return type of functions that never return they panic, loop forever, or call a no-return
function:

```kairo
fn fatal(msg: string) panic -> ! {
    panic std::Error::Runtime(msg)
}
```

`!` is a subtype of every type, making it valid in expression contexts:

```kairo
var x: i32 = if valid { compute() } else { fatal("bad state") }
```

`!` can only appear as a function return type. It cannot be used as a variable type, type parameter,
or in any other type position:

```kairo
// var x: !          // compile error
// var y: Foo<!>     // compile error
```

See [Functions](/docs/language/functions#no-return-) for no-return function semantics.

---

## Void - The Absence of a Value - Unit Types

`void` represents the absence of a value. It is the default return type for functions with no explicit
return type.

`void` can be used as a type parameter, but can not be used as a variable type:

```kairo
var handle: unsafe *void = get_opaque_handle()
var safe_handle:   *void = get_tracked_handle()

var y: Foo<void>  // valid - ok
var x: void       // compile error
```

See [Primitives](/docs/language/primitives#void) for details.

---

## Nullable Types in the Type System

`T?` is syntactic sugar for the compiler-intrinsic `Nullable<T>` tagged union. `Nullable` is not
directly usable as a type name use the `?` suffix:

```kairo
var x: i32? = 42
var y: string? = null
```

### Nested nullables

`T??` is a parser error because `??` is the null-coalescing operator. Use parentheses for nested
nullables:

```kairo
// var x: i32??     // parse error: ?? is an operator
var x: (i32?)? = null   // ok: Nullable<Nullable<i32>>
```

Nested nullables are rarely useful. If you find yourself writing `(T?)?`, reconsider the data model.

See [Variables](/docs/language/variables#nullable-types) for null checking, safe access, and unwrapping.

---

## Tuple Types

Tuples are fixed-size, heterogeneous, ordered groups of values:

```kairo
var point: (f64, f64) = (1.0, 2.0)
var record: (i32, string, bool) = (42, "answer", true)
```

Single-element tuples do not exist. `(T)` is just `T` the parentheses are grouping, not a tuple
constructor:

```kairo
var x: (i32) = 42   // same as var x: i32 = 42
```

There is no unit type or empty tuple `()`. Functions that return nothing use `void`.

See [Primitives](/docs/language/primitives#tuples-t1-t2-) for tuple syntax and
[Variables](/docs/language/variables#destructuring) for tuple destructuring.

---

## Function Types

Function pointer types are written as `fn(ParamTypes) -> ReturnType`:

```kairo
var add: fn(i32, i32) -> i32 = fn (a: i32, b: i32) -> i32 { return a + b }
var log: fn(string) -> void = std::println
```

The `panic` modifier can appear on function types to indicate the function may panic. Callers must
handle the panic via `try`/`catch`:

```kairo
var risky: fn(i32) panic -> i32 = some_panicking_function

try {
    risky(42)
} catch e {
    // handle
}
```

No other modifiers (`const`, `async`, `eval`, `unsafe`) are valid on function pointer types. `const`
is a property of methods (it constrains `self`), not of the function signature. `unsafe` selects a
different overload namespace, not a different type. `async` and `eval` require named function
declarations.

See [Functions](/docs/language/functions#function-pointers) and
[Closures](/docs/language/closures) for function pointer usage.

---

## Collection Types

Collection literal syntax maps to built-in types:

| Syntax | Type | Description |
|---|---|---|
| `[T]` | Vector | Growable contiguous array that owns a heap copy of its elements (ptr + len + cap) |
| `[T;]` | Slice | Non-owning view over contiguous elements (ptr + len) |
| `[T; N]` | Array | Fixed-size, stored inline, `N` must be compile-time; not copyable or assignable |
| `{K: V}` | Map | Hash map |
| `{T}` | Set | Hash set |

These are primitives in the type system, not generic library types. The standard library provides
type aliases for the explicit names:

```kairo
// In module std:
type <T> Vector = [T]
type <T, N> Array = [T; N]
type <K, V> HashMap = {K: V}
type <T> HashSet = {T}
```

The literal syntax and the aliased names are interchangeable.

A list literal `[a, b, c]` is an array `[T; 3]` unless its target is a slice or a vector. Arrays are not
value types: they cannot be copied, assigned, passed by value, or returned. See
[Primitives](/docs/language/primitives#collections) for the full rules on arrays, slices, vectors, and list
literals.

`N` in `[T; N]` must be a compile-time evaluable expression. Runtime-dependent array sizes are not
supported use `[T]` (vector) for dynamically sized collections:

```kairo
eval SIZE = 256
var buffer: [u8; SIZE] = [0; SIZE]    // ok: SIZE is compile-time

// var dynamic: [u8; runtime_val]     // compile error: N must be compile-time
```

See [Eval](/docs/language/eval) for compile-time evaluation rules.

---

## Typeof Identity Semantics

`typeof` has dual behavior depending on whether it appears in a type position or an expression position:

### Type position

In a type position, `typeof` resolves to the compile-time type of the expression:

```kairo
var x = 42
var y: typeof x = 100   // typeof x resolves to i32 at compile time
```

### Expression position

In an expression position, `typeof` returns a `TypeInfo` object:

```kairo
var x = 42
var info = typeof x
info.get_pretty_name()   // "i32"
info.get_size()          // 4
info.get_align()         // 4
```

### TypeInfo

`TypeInfo` is a built-in class that describes a type at runtime:

```kairo
class TypeInfo {
    fn get_name(const self) -> string        // mangled ABI name
    fn get_pretty_name(const self) -> string  // human-readable (e.g. "HashMap<string, i32>")
    fn get_size(const self) -> usize
    fn get_align(const self) -> usize
    fn get_abi_format(const self) -> string   // ABI format string for interop
    fn get_kind(const self) -> TypeKind
}

enum TypeKind {
    Primitive,
    Struct,
    Class,
    Enum,
    Union,
    Function,
    Interface,
}
```

`get_name()` returns the mangled name following the platform's C++ ABI (Itanium on Unix, MSVC on
Windows). `get_pretty_name()` returns a human-readable string including generic arguments.

> [!IMPORTANT]
> The `TypeInfo` API is still being finalized. Additional methods for querying members, base classes,
> and interface conformance may be added in a future update.

### Compile-time `typeof`

`typeof` in `eval if` conditions is resolved at compile time:

```kairo
fn <T> process(x: T) {
    eval if typeof T == i32 {
        // only compiled when T is i32
        fast_int_path(x)
    } else {
        generic_path(x)
    }
}
```

See [Eval](/docs/language/eval) for compile-time evaluation and
[Control Flow](/docs/language/control-flow#compile-time-branching) for `eval if`.

---

## Self

`Self` is a type alias that resolves to the enclosing type. It is available in:

- [Class](/docs/language/classes#self-and-self) bodies and methods
- [Interface](/docs/language/interfaces#operators-in-interfaces) signatures
- [Extend](/docs/language/extends) blocks

`Self` always refers to a reference to the type. For a pointer, use `*Self`. In a generic class
`class <T> Foo`, `Self` resolves to `Foo<T>`:

```kairo
class <T> Hold {
    var value: T

    fn Hold(self, v: T) { self.value = v }

    fn replace(self, other: Self) {
        // Self is Hold<T>
        self.value = other.value
    }
}
```

`Self` is not available in free functions or at the top level.

---

## Type Identity

Two types are the same if they have the same fully qualified name and the same generic arguments.
This is nominal identity, not structural:

```kairo
struct Point { var x: f64; var y: f64 }
struct Vec2  { var x: f64; var y: f64 }

// Point and Vec2 are different types despite identical structure
// var p: Point = Vec2 { x: 1.0, y: 2.0 }   // compile error
```

Generic types are identified by their monomorphized form. `Foo<i32>` and `Foo<i64>` are different
types. `Foo<i32>` in one translation unit is the same type as `Foo<i32>` in another identity
follows the platform's C++ ABI mangling rules.

Type aliases are transparent (unless `-fno-type-aliasing` is set) the alias and the original type
are the same type for identity purposes.

---

## Summary

```kairo
// Type alias
type Meters = f64
type <T> Pair = (T, T)

// Type inference
var x = 42                          // i32
var y = [1.0, 2.0]                  // [f64]
fn <T> id(x: T) -> T = x
id(42)                              // T inferred as i32

// Implicit conversions
var n: i64 = 42i32                  // numeric widening
var s: string? = "hello"            // T to T?
var a: *Animal = &Dog("Rex", "Lab") // derived-to-base pointer

// Nullable
var x: i32? = null
var y = x ?? 0                      // null coalescing

// typeof
var info = typeof x
info.get_pretty_name()              // "Nullable<i32>"
var z: typeof x = 10                // type position: resolves to i32?

// Function types
var f: fn(i32) -> i32 = fn (x: i32) -> i32 { return x * 2 }
var g: fn(i32) panic -> i32 = risky_fn

// Collections
var vec: [i32] = [1, 2, 3]
var view: [i32;] = [1, 2, 3]
var arr: [u8; 4] = [0, 0, 0, 0]
var map: {string: i32} = {"a": 1}
var set: {i32} = {1, 2, 3}
```

# Using Kairo in C++

## Exposing Kairo to C++

Use the **`kcc`** driver, which makes `#include "file.k"` work transparently in C++ translation units.

```kairo
// my_code.k
import std::io

pub fn my_kairo_function(x: i32) {
    io::println(f"Hello from Kairo! x = {x}")
}

pub class MyKairoClass {
    pub var name: string

    pub fn MyKairoClass(self, name: string) {
        self.name = name
    }

    pub fn get_name(self) -> string {
        return self.name
    }
}
```

```cpp
// main.cpp
#include "my_code.k"
#include <iostream>

int main() {
    // A Kairo string is ::builtin::string::string; it is built from
    // `const unsigned char*`, not from a C++ string literal directly.
    ::builtin::string::string name((const unsigned char*)"C++");
    my_code::MyKairoClass obj(name);
    std::cout << "name = " << obj.get_name().c_str() << std::endl;
    my_code::my_kairo_function(42);
    return 0;
}
```

```sh
kcc main.cpp -o main
./main
```

```
name = C++
Hello from Kairo! x = 42
```

`my_code.k` is not on the command line: `kcc` finds it in `main.cpp`, builds it and links it. Its declarations are in its [module namespace](/docs/language/modules/#module-paths-are-c-namespaces), `my_code`, as they are for a Kairo importer. That namespace is the file's path under the [search directory](/docs/language/modules/#search-directories-and-library-names) that holds it, the same as for a file named on the command line: run from the project root, a `src/my_code.k` would be `src::my_code`, unless `-I src` makes `src` a search directory of its own.

### When a module's name is taken in C++

The first part of a module's namespace sits at C++ global scope. When that name is already something else there, Kairo renames the namespace by one fixed rule: it appends `_`, and keeps appending while the name is still taken. Your Kairo code is unaffected (it still says `main::x` or `import malloc`); only the C++ spelling changes.

A name is taken when it is:

- a program entry point: `main`, `wmain`, `WinMain`, `wWinMain`, `DllMain` or `_start`;
- declared at global scope, as anything but a namespace, by a C or C++ header the build includes (`malloc`, `free` and `exit` come from `<stdlib.h>`, which the runtime always includes);
- another module's own top-level name in the same build.

| Kairo module | C++ namespace |
|---|---|
| `main.k` | `main_` |
| `main/x.k` (`main::x`) | `main_::x` |
| `malloc.k` | `malloc_` |
| `exit.k` | `exit_` |
| `abort.k`, when a header also declares `::abort_` | `abort__` |
| `printf.k`, when no included header declares `::printf` | `printf` |

A C++ file calls such a module through the renamed namespace:

```cpp
#include "malloc.k"
#include <cstdlib>

int main() {
    void* p = ::malloc(16);           // the C function
    int r = malloc_::helper();        // Kairo's malloc.k
    ::free(p);
    return r;
}
```

The decision is made once per build, from the headers that build includes, so every object and header of the build agrees on it. A module name that only *your* C++ file's headers declare (and no header of the Kairo build) is not renamed; pick another file name for it. Link errors name the C++ symbol (`malloc_::helper()`); Kairo's own diagnostics name the module as you wrote it.

### What crosses an include

An included `.k` gives C++ the same interface a Kairo importer sees:

- Its `pub` declarations, and its `prot` ones when the C++ file is in the same [module](/docs/language/modules/#visibility-scopes) (under the same nearest `module.k`). A `priv` or `internal` top-level declaration is left out, and so is a `prot` one for a C++ file outside the module, unless a visible `inline` or generic body names it (that body is compiled by the C++ code, so it must see what it calls). C++ has no way to keep a declaration from the rest of its translation unit, so that is the only one that crosses. An unmarked declaration counts as what its default makes it: `priv`, or `prot` under a `module.k`.
- Every class member at its own visibility: a `priv` member is `private:`, a `prot` one `protected:` (`public:` when the class's file is in a module, since C++ cannot say "this module"; such a member is then reachable from any C++ file that sees the class), a `pub` one `public:`. An unmarked member that is `priv` by default is `private:` too, except an operator, which stays public so C++ templates that test for it (`a == b`, the panic helpers' `op panic`) see what Kairo sees. Kairo's `priv` reaches every function of the class's file, which C++ says by making the class befriend that file's functions and types, so the module's own `inline` and generic functions still work when the C++ code compiles them. The C++ code itself cannot read a `priv` field or call a `priv` method. Some members are public in C++ whatever their Kairo visibility: copy and move constructors and destructors (so C++ containers can hold the type), and the fields of a struct, of a union, and of a class with no constructor (these are plain aggregates, built with designated initializers, and a struct keeps the C layout and calling convention). Every base is a public base; a `derives priv` (or `prot`) base's members are private (protected) through the derived class, through using-declarations.
- The bodies of templates and `inline` functions; every other body stays in the `.k`'s object.
- Its types' dependencies, from other modules and from the builtin library, declared once per translation unit however many `.k` files include them.

How `kcc` processes `#include "file.k"`, separate compilation, and the manual workflow without `kcc` are covered in [kairo, kcc & Cross-compilation](/docs/language/c-cpp-toolchain/#how-kcc-works).

---

## Using Kairo from C++

### Headers

Every module can emit a C++ header, the files given on the command line included; only a file outside every search directory and every library has none. `--emit-headers <dir>` writes one per module at a path mirroring the [module path](/docs/language/modules/#module-paths-are-c-namespaces): `geo::vec` becomes `<dir>/geo/vec.hh`. A C++ file includes it the way Kairo would import it:

```cpp
#include "geo/vec.hh"      // Kairo: import geo::vec
```

A header contains the module's [`pub` declarations](/docs/language/modules/#visibility-on-top-level-declarations) in their canonical namespaces (a header has no including file to check, so it never carries `prot` ones), declarations only: class layouts, function signatures, enum definitions. Function bodies are in the module's object file; you compile the module with Kairo and link the result. A header `#include`s the headers of modules its layouts depend on and forward-declares everything else, so including one module does not drag in the tree.

A module that defines nothing (only comments, or only [`pub import` re-exports](/docs/language/imports/#re-export-pattern)) produces no object file and no header. C++ code that would include the header of a re-export-only module includes the headers of the modules it re-exports instead.

### What a Kairo declaration looks like in C++

| Kairo | C++ |
|---|---|
| `pub struct Vec2 { ... }` in `geo/vec.k` | `geo::vec::Vec2` |
| `pub fn dot(a: Vec2, b: Vec2) -> f64` | `double geo::vec::dot(Vec2, Vec2)` |
| `pub class <T> Box { ... }` | `template <class T> class geo::vec::Box` |
| `enum Dir derives u8 { N, S }` | `enum class Dir : std::uint8_t { N, S }` |
| `fn m(self)` inside a class | member function |
| `fn m(self)` inside `extend Vec2 { }` | static function `m(Vec2* self)` of the companion struct `geo::vec::__kairo_ext_Vec2` |
| `x: i32`, `x: f64`, `x: usize` | `std::int32_t`, `double`, `std::size_t` |
| `p: *T` | `T*` |
| `x: T?` | `::builtin::Nullable<T>` (see [Nullables Across the Boundary](#nullables-across-the-boundary)) |
| `null` | `::builtin::null` |
| `@inout x: T`, `@move x: T` | `T&`, `T&&` |
| `type Name = T` inside a class | `using Name = T;` member, under the same access level |
| `@no_unwind fn f()` | `void f() noexcept` |
| `f: fn(i32) -> i32` | `::__kairo_fn<std::int32_t(std::int32_t)>`, a function or closure value |
| `f: unsafe fn(i32) -> i32` | `std::int32_t (*)(std::int32_t)`, a plain function pointer |
| `ffi "c" fn apply(f: fn(i32) -> i32, x: i32) -> i32` | `extern "C" std::int32_t apply(std::int32_t (*f)(std::int32_t), std::int32_t x)` |

An `ffi "c"` function's `fn` parameters and result are raw function pointers whether or not they are written `unsafe fn`, because C passes and expects a plain function pointer. A Kairo caller can pass a named function or a closure that captures nothing; passing a capturing closure is a compile error.

Extension methods are not C++ member functions. Kairo keeps a class's C++ definition identical everywhere it appears, so a method added by [`extend`](/docs/language/extends/), even in the same file, is a static function of a companion struct emitted beside the type, taking the receiver as its first parameter: `geo::vec::__kairo_ext_Vec2::len(&v)`. When the `extend` is in the type's own file, the type befriends the companion, so extension members reach `priv` members in C++ as they do in Kairo. An `extend` in another file puts its companion in that file's namespace, and the type does not befriend it. An operator added by `extend` is also a free C++ operator that forwards to the companion, so C++ code writes `a + b`.

Member [type aliases](/docs/language/type-aliases/) are visible to C++: a class's `type promise_type = ...` is the C++ member `promise_type`, so C++ code that looks a member type up by name finds it.

Names beginning `__kairo_` are reserved. A rendered class may expose public `__kairo_` members; C++ code must not read or write them.

### Allocation from C++

Every Kairo class, struct and ADT enum in C++-facing output carries class-scope `operator new` / `operator delete` (and the array, aligned, `nothrow` and placement forms) that use Kairo's allocator. `new MyKairoType()` and `delete p` in C++ therefore pair correctly with `@create` and `@destroy` on the Kairo side, and a C++ global `operator new` override never reaches a Kairo object. See [Allocators & Ownership](/docs/language/c-cpp-memory/#class-specific-operator-new-and-operator-delete).

### Generics

Kairo [generics](/docs/language/generics/) are C++ templates in the header, bodies included. Instances Kairo already compiled are listed as `extern template`, so linking against the module's objects reuses them; any other instance is instantiated by your C++ compiler like any template. An `#include "file.k"` lists none: the C++ side instantiates every instance it uses, and the linker keeps one copy. A Kairo `impl` bound on a generic function or method is a C++ constraint: each interface is emitted as a C++ concept (`Shape` is `Shape_c`, in the interface's namespace), and the template carries `requires(Shape_c<T>)`, so a C++ call with a type that does not satisfy the bound is rejected at the call. A bound on a generic class or struct is not translated: the class template is unconstrained, and instantiating it with a type that does not satisfy the bound fails inside the member that needs it. Each instance Kairo compiled also carries a `static_assert` that its bounds hold.

### Constructing enum variants from C++

An [ADT enum](/docs/language/enums-adt/) is a class in C++, and each of its variants has a static factory function named exactly after the variant:

```kairo
// packet.k
pub enum <T> Frame {
    Burst { base: T, count: i32 },
    Code  { status: i32 },
    Idle,
}
```

```cpp
#include "packet.k"

packet::Frame<int> a = packet::Frame<int>::Burst(20, 4);
packet::Frame<int> b = packet::Frame<int>::Code(404);
packet::Frame<int> c = packet::Frame<int>::Idle();
```

- The parameters are the variant's fields, in declaration order and with the fields' names. A variant without a payload has a factory that takes no arguments: write `Frame<int>::Idle()`, with the parentheses.
- The factories exist in the C++ view only (a header from `--emit-headers` or an `#include "file.k"`). They are inline, so an unused one costs nothing, and they work at every instance of a generic enum.
- Each factory is a member template with a defaulted parameter, so a call reads like an ordinary static function. Taking its address needs empty angle brackets: `&Frame<int>::Burst<>`.
- If the variant's name is already taken in the C++ class, the factory gets a `_` appended, repeated until the name is free. A name is taken when it is the enum's own name (that name belongs to the constructors), one of its type parameters, or a member the compiler gives the class. Variants whose own names are free keep them, so in `enum Node { Node { v: i32 }, Node_ { v: i32 } }` the factories are `Node::Node__` and `Node::Node_`.
- No factory is generated for a pack-expanded variant of a [variadic enum](/docs/language/enums-adt/#variadic-enums), for a variant with a fixed-size array field, or for the panic result type.

[Plain enums](/docs/language/enums-plain/) need no factories: a variant is already the C++ enumerator `Dir::N`.

---

## Tuples Across the Boundary

Kairo [tuples](/docs/language/collections/#tuples-t1-t2-) such as `(i32, f32)` are emitted as the struct template `::builtin::TupleN<T0, T1, ...>` (`::builtin::Tuple2<int, float>`), one instance per distinct element-type list. Field order is source order: the fields are `_0`, `_1`, ..., and `.0` lowers to a plain member access.

This makes tuples first-class across the boundary: a C++ TU can name the type, take a reference to it, return it, and specialize on it.

The type is a **structural** function of its element types, not an ordinal. Two translation units that use `(i32, f32)` produce the same type and the same symbol, regardless of declaration order or which other tuple shapes appear in each TU. This is required for linking and is a departure from C++'s anonymous-type mangling, which is deliberately TU-local.

> [!NOTE]
> The exact structural encoding is part of the ABI and is specified separately. It is injective across all type constructors that can appear in a tuple, and unambiguous under nesting.

---

## Nullables Across the Boundary

A Kairo [nullable](/docs/language/nullables/) `T?` is the C++ class template `::builtin::Nullable<T>`, and Kairo's `null` is the constant `::builtin::null`, the one value of the empty type `::builtin::null_t`. `Nullable<T>` has two constructors, one from `null_t` and one from `T`, so C++ code builds one the same way Kairo's implicit conversions do:

```cpp
::builtin::Nullable<int> a = ::builtin::null;   // Kairo: var a: i32? = null
::builtin::Nullable<int> b = 5;                 // Kairo: var b: i32? = 5
```

The layout depends on `T`:

| Kairo | Storage |
|---|---|
| `*T?` (any safe pointer, `const` included) | the pointer alone, `sizeof(T*)`; null is `0x0` |
| a closed [enum](/docs/language/enums-plain/#closed-and-open-enums) `E?` | the enum alone, `sizeof(E)`; null is a value `E` does not declare |
| `bool?` | two bytes, the `bool` and a presence flag; one byte, with `0x02` as null, is planned ([Status](/docs/status/#not-compiled-yet)) |
| any other `T?` | the `T` and a presence flag |

`(T?)?` is `Nullable<Nullable<T>>`.

---

## See also

- [C & C++ Interoperability](/docs/language/c-cpp/)
- [kairo, kcc & Cross-compilation](/docs/language/c-cpp-toolchain/)
- [Calling C and C++ from Kairo](/docs/language/c-cpp-calling/)
- [Allocators & Ownership](/docs/language/c-cpp-memory/)
- [Exceptions & Panics](/docs/language/c-cpp-exceptions/)
- [ABI Contract & Verification](/docs/language/c-cpp-abi/)
- [Modules](/docs/language/modules/)
- [Generics](/docs/language/generics/)

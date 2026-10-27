# Using Kairo in C++

## Exposing Kairo to C++

Use the **`kcc`** driver, which makes `#include "file.k"` work transparently in C++ translation units.

```kairo
// my_code.k
fn my_kairo_function(x: i32) {
    std::println(f"Hello from Kairo! x = {x}")
}

class MyKairoClass {
    pub var name: string

    fn MyKairoClass(self, name: string) {
        self.name = name
    }

    fn get_name(self) -> string {
        return self.name
    }
}
```

```cpp
// main.cpp
#include "my_code.k"
#include <iostream>

int main() {
    my_code::MyKairoClass obj("C++");
    std::cout << "name = " << obj.get_name() << std::endl;
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

### What crosses an include

An included `.k` gives C++ the same interface a Kairo importer sees:

- Its `pub` declarations. A `priv` or `internal` top-level declaration is left out, unless a `pub` `inline` or generic body names it (that body is compiled by the C++ code, so it must see what it calls). C++ has no way to keep a declaration from the rest of its translation unit, so that is the only one that crosses.
- `priv` class members as `private:` members.
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

A header contains the module's [`pub` declarations](/docs/language/modules/#visibility-on-top-level-declarations) in their canonical namespaces, declarations only: class layouts, function signatures, enum definitions. Function bodies are in the module's object file; you compile the module with Kairo and link the result. A header `#include`s the headers of modules its layouts depend on and forward-declares everything else, so including one module does not drag in the tree.

A module that defines nothing (only comments, or only [`pub import` re-exports](/docs/language/imports/#re-export-pattern)) produces no object file and no header. C++ code that would include the header of a re-export-only module includes the headers of the modules it re-exports instead.

### What a Kairo declaration looks like in C++

| Kairo | C++ |
|---|---|
| `pub struct Vec2 { ... }` in `geo/vec.k` | `geo::vec::Vec2` |
| `pub fn dot(a: Vec2, b: Vec2) -> f64` | `double geo::vec::dot(Vec2, Vec2)` |
| `pub class <T> Box { ... }` | `template <class T> class geo::vec::Box` |
| `enum Dir derives u8 { N, S }` | `enum class Dir : std::uint8_t { N, S }` |
| `fn m(self)` inside a class | member function |
| `fn m(self)` inside `extend Vec2 { }` | free function `geo::vec::m(Vec2* self)` |
| `x: i32`, `x: f64`, `x: usize` | `std::int32_t`, `double`, `std::size_t` |
| `p: *T` | `T*` |
| `x: T?` | `::builtin::Nullable<T>` (see [Nullables Across the Boundary](#nullables-across-the-boundary)) |
| `null` | `::builtin::null` |
| `@inout x: T`, `@move x: T` | `T&`, `T&&` |
| `type Name = T` inside a class | `using Name = T;` member, under the same access level |
| `@no_unwind fn f()` | `void f() noexcept` |

Extension methods are not C++ member functions. Kairo keeps a class's C++ definition identical everywhere it appears, so a method added by [`extend`](/docs/language/extends/), even in the same file, is a free function taking the receiver as its first parameter. Call it as `geo::vec::len(&v)`.

Member [type aliases](/docs/language/type-aliases/) are visible to C++: a class's `type promise_type = ...` is the C++ member `promise_type`, so C++ code that looks a member type up by name finds it.

Names beginning `__kairo_` are reserved. A rendered class may expose public `__kairo_` members; C++ code must not read or write them.

### Generics

Kairo [generics](/docs/language/generics/) are C++ templates in the header, bodies included. Instances Kairo already compiled are listed as `extern template`, so linking against the module's objects reuses them; any other instance is instantiated by your C++ compiler like any template. An `#include "file.k"` lists none: the C++ side instantiates every instance it uses, and the linker keeps one copy. Kairo's `impl` bounds are not translated to C++ constraints: instantiating a Kairo generic with a C++ type that does not satisfy the bound fails inside the template body rather than at the call.

---

## Tuples Across the Boundary

Kairo [tuples](/docs/language/collections/#tuples-t1-t2-) such as `(i32, f32)` are emitted as ordinary named structs in a reserved namespace, one per distinct element-type list. Field order is source order, and `.0` lowers to a plain member access.

This makes tuples first-class across the boundary: a C++ TU can name the type, take a reference to it, return it, and specialize on it.

The struct's name is a **structural** function of its element types, not an ordinal. Two translation units that use `(i32, f32)` produce the same type and the same symbol, regardless of declaration order or which other tuple shapes appear in each TU. This is required for linking and is a departure from C++'s anonymous-type mangling, which is deliberately TU-local.

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
| `bool?` | one byte; `0x02` is null |
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

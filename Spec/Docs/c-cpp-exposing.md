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
    MyKairoClass obj("C++");
    std::cout << "name = " << obj.get_name() << std::endl;
    my_kairo_function(42);
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

How `kcc` processes `#include "file.k"`, and the manual workflow without `kcc`, are covered in [kairo, kcc & Cross-compilation](/docs/language/c-cpp-toolchain/#how-kcc-works).

---

## Using Kairo from C++

### Headers

Every non-entry module can emit a C++ header. `--emit-headers <dir>` writes one per module at a path mirroring the [module path](/docs/language/modules/#module-paths-are-c-namespaces): `geo::vec` becomes `<dir>/geo/vec.hh`. A C++ file includes it the way Kairo would import it:

```cpp
#include "geo/vec.hh"      // Kairo: import geo::vec
```

A header contains the module's [`pub` declarations](/docs/language/modules/#visibility-on-top-level-declarations) in their canonical namespaces, declarations only: class layouts, function signatures, enum definitions. Function bodies are in the module's object file; you compile the module with Kairo and link the result. A header `#include`s the headers of modules its layouts depend on and forward-declares everything else, so including one module does not drag in the tree.

A module that defines nothing (only comments, or only [`pub import` re-exports](/docs/language/imports/#re-export-pattern)) produces no object file and no
header. C++ code that would include the header of a re-export-only module includes the headers of the modules
it re-exports instead.

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
| `@inout x: T`, `@move x: T` | `T&`, `T&&` |
| `type Name = T` inside a class | `using Name = T;` member, under the same access level |
| `@no_unwind fn f()` | `void f() noexcept` |

Extension methods are not C++ member functions. Kairo keeps a class's C++ definition identical everywhere it appears, so a method added by [`extend`](/docs/language/extends/), even in the same file, is a free function taking the receiver as its first parameter. Call it as `geo::vec::len(&v)`.

Member [type aliases](/docs/language/type-aliases/) are visible to C++: a class's `type promise_type = ...` is the C++ member
`promise_type`, so C++ code that looks a member type up by name finds it.

Names beginning `__kairo_` are reserved. A rendered class may expose public `__kairo_` members; C++ code
must not read or write them.

### Generics

Kairo [generics](/docs/language/generics/) are C++ templates in the header, bodies included. Instances Kairo already compiled are listed as `extern template`, so linking against the module's objects reuses them; any other instance is instantiated by your C++ compiler like any template. Kairo's `impl` bounds are not translated to C++ constraints: instantiating a Kairo generic with a C++ type that does not satisfy the bound fails inside the template body rather than at the call.

---

## Tuples Across the Boundary

Kairo [tuples](/docs/language/collections/#tuples-t1-t2-) such as `(i32, f32)` are emitted as ordinary named structs in a reserved namespace, one per distinct
element-type list. Field order is source order, and `.0` lowers to a plain member access.

This makes tuples first-class across the boundary: a C++ TU can name the type, take a reference to it, return it,
and specialize on it.

The struct's name is a **structural** function of its element types, not an ordinal. Two translation units that
use `(i32, f32)` produce the same type and the same symbol, regardless of declaration order or which other tuple
shapes appear in each TU. This is required for linking and is a departure from C++'s anonymous-type mangling,
which is deliberately TU-local.

> [!NOTE]
> The exact structural encoding is part of the ABI and is specified separately. It is injective across all type
> constructors that can appear in a tuple, and unambiguous under nesting.

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

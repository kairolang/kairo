# C & C++ Interoperability

Kairo provides zero-overhead, bidirectional interoperability with C and C++. There is no serialization layer, no
binding generator, and no runtime bridge Kairo emits ABI-compatible object code and consumes C/C++ headers
directly.

This page covers the full interop surface: calling C/C++ from Kairo, exposing Kairo to C/C++, inline C++ blocks,
pointer and reference passing, templates and concepts across the boundary, exception interop, and the underlying
ABI contract.

---

## Coverage Matrix

The table below summarizes which C and C++ features Kairo can consume and expose. Rows marked
**bidirectional** work in both directions.

| Feature | Direction | Notes |
|---|---|---|
| Functions | Bidirectional | Includes variadic functions |
| Structs | Bidirectional | Layout-compatible; see [Structs](/docs/structs) |
| Unions | Bidirectional | See [Unions](/docs/unions) |
| Enums | Bidirectional | See [Enums](/docs/enums) |
| Classes | Bidirectional | Vtable-compatible; see [Classes](/docs/classes) |
| Templates | Bidirectional | Instantiation across the boundary; see [below](#templates-and-concepts) |
| Concepts | Bidirectional | Kairo's `impl` constraints map to C++20 concepts |
| Namespaces | Bidirectional | |
| Pointers & References | Bidirectional | Requires `unsafe` on the Kairo side; see [below](#pointers-and-references) |
| Operator Overloading | Bidirectional | See [Operators](/docs/operators) |
| Lambdas | Bidirectional | |
| Exceptions | C++ -> Kairo | Kairo -> C++ is on the roadmap |
| Macros | C++ -> Kairo | Preprocessor macros are expanded before Kairo sees them |
| Preprocessor Directives | C++ -> Kairo | |
| Inline Assembly | Kairo -> C++ | Via `inline "c++"` blocks |
| Coroutines | Bidirectional | |
| Named Modules (`import std;`) | Not yet | See [Modules note](#a-note-on-c-modules) |

---

## Calling C/C++ from Kairo

Import a C or C++ header with the `ffi` directive. The compiler parses the header, extracts declarations, and
makes them available as native Kairo symbols no wrapper code required.

```kairo
// main.k
ffi "c++" import "my_code.hh";

fn main() {
    var obj = MyClass("Kairo")
    std::println(f"name = {obj.get_name()}")
    my_function(42)
}
```

Given this C++ header:

```cpp
// my_code.hh
#include <string>
#include <iostream>

class MyClass {
public:
    MyClass(std::string name) : name(name) {}
    std::string get_name() const { return name; }
private:
    std::string name;
};

void my_function(int x) {
    std::cout << "Hello from C++! x = " << x << std::endl;
}
```

Build and run:

```sh
kairo main.k
./main
```

```
name = Kairo
Hello from C++! x = 42
```

> [!NOTE] `ffi "c++"` invokes Clang's frontend internally to parse the header. All exported
> declarations functions, classes, enums, templates become available in Kairo's scope with their original
> names and signatures. No code generation or binding step is visible to the user.

---

## Exposing Kairo to C++

Going the other direction requires the **`kcc`** driver, a libclang-based compiler wrapper that makes
`#include "file.k"` work transparently in C++ translation units.

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

### How `kcc` works

`kcc` is a Clang driver with a single addition: a preprocessor hook that intercepts `#include` directives. When
the included file has a `.k` extension, `kcc`:

1. Invokes the Kairo compiler **in-process as a library** to produce a C++-compatible header containing forward
   declarations and wrapper signatures.
2. Compiles the `.k` file into an object file.
3. Links the Kairo object into the final binary at the end of the pipeline.

Auto-linking can be disabled with **`-fno-kairo-link`** if you need manual control over the link step.

### Manual workflow (without `kcc`)

If you prefer a standard C++ build process, compile the Kairo source to a static library and a generated header,
then link normally:

```sh
kairo my_code.k -c -o my_code -xc++ -header my_code.hh
g++ main.cpp my_code.o -o main
```

> [!TIP]
> `kcc` is the simplest path for mixed codebases. The manual workflow is better when Kairo
> is a dependency consumed by an existing CMake/Meson/Bazel project that manages its own link step.

---

## The `ffi` Keyword

`ffi` controls linkage and name mangling. It can be applied to individual declarations or to blocks.

```kairo
// C++ linkage name mangling, overloading, classes, templates all permitted
ffi "c++" {
    fn compute(x: i32) -> i32 {
        return x + 1;
    }
}

// C linkage no name mangling, same restrictions as extern "C" in C++
ffi "c" fn add(x: i32, y: i32) -> i32 {
    return x + y;
}
```

`ffi "c"` follows the same rules as `extern "C"` in C++: no classes, no overloading, no templates.
`ffi "c++"` follows the same rules as `extern "C++"`: full C++ feature set, Itanium or MSVC mangling depending
on the target.

---

## Inline C++

For small amounts of C++ that don't warrant a separate header, use `inline "c++"` blocks directly in Kairo
source.

```kairo
import libcxx::iostream::{cout, endl};

fn main() {
    inline "c++" {
        // std:: here refers to Kairo's standard library, not libstdc++
        std::println("Hello from inline C++!");

        // C++ standard library types use the libcxx:: prefix
        cout << "Hello from libcxx!" << endl;
    }
}
```

> [!WARNING]
> Inside `inline "c++"` blocks, `std::` resolves to the **Kairo** standard library
> (the block emits inside `namespace kairo`). Access the C++ standard library through the `libcxx` module,
> importing the specific header you need (e.g., `import libcxx::vector;`). See [Modules](/docs/modules) for
> more on imports.

---

## Pointers and References

Kairo's [pointer model](/docs/pointers) distinguishes safe pointers (`*T`, non-nullable, bounds-tracked) from raw
pointers (`unsafe *T`, no tracking). Passing any pointer or reference across the FFI boundary requires explicit
`unsafe` context because the compiler cannot enforce safety guarantees on the C/C++ side.

### Safe variable, unsafe pass

```kairo
ffi "c++" import "my_code.hh";

fn main() {
    var x = 41

    // compile error: cannot pass reference to C function without unsafe block
    // add_one(&x)

    unsafe {
        add_one(unsafe &x)  // strips bounds checking; caller owns the memory contract
    }

    // for calling c++ with pointers and back, you must use unsafe blocks,
    // short hand syntax is not allowed `unsafe add_one(unsafe &x)` is a compile error

    std::println(f"x = {x}")  // x = 42
}
```

`unsafe &` creates a raw pointer from a safe binding. The compiler relinquishes tracking for that pointer the
caller is responsible for lifetime and aliasing correctness.

### Raw pointer from the start

If the value will be passed to C/C++ repeatedly, allocate it as a raw pointer upfront:

```kairo
ffi "c++" import "my_code.hh";

fn main() {
    var x: unsafe *i32 = std::create<i32>(41)
    add_one(x)  // already unsafe no block needed
    std::println(f"x = {*x}")  // x = 42
}
```

> [!WARNING]
> `std::create<T>` uses Kairo's global allocator, which is compatible with
> C++'s `new`/`delete` by default. If you supply a custom allocator, C++ code **must not** free the resulting
> pointer with `delete` doing so is undefined behavior. See [AMT](/docs/amt) for allocator details.

> [!WARNING]
> `unsafe *T` pointers can be null. Dereferencing a null `unsafe *T` is undefined
> behavior the compiler will not insert a null check.

---

## Templates and Concepts

Kairo generics and C++ templates are interchangeable across the boundary. A C++ concept can constrain a Kairo
generic parameter, and a Kairo generic type can satisfy a C++ concept.

```cpp
// my_code.hh
#include <concepts>

template<typename T>
concept Addable = requires(T a, T b) {
    { a + b } -> std::same_as<T>;
};
```

```kairo
// MyInt.k
ffi "c++" import "my_code.hh";

class <T> MyInt {
    pub var value: T

    fn MyInt(self, value: T) {
        self.value = value
    }

    fn op + (self, other: MyInt) -> MyInt {
        return MyInt(self.value + other.value)
    }
}

fn <T impl Addable> add(a: T, b: T) -> T {
    return a + b
}
```

```cpp
// main.cpp
#include <iostream>
#include "my_code.hh"
#include "MyInt.k"

int main() {
    MyInt<int> a(5), b(10);
    MyInt<int> c = add(a, b);
    std::cout << "c.value = " << c.value << std::endl;  // 15

    int x = add(3, 4);
    std::cout << "x = " << x << std::endl;  // 7
}
```

`T impl Addable` in Kairo maps directly to `Addable T` in the generated C++ the constraint is preserved across
the boundary, not erased.

---

## Exceptions

Kairo can catch C++ exceptions using its standard `try`/`catch` syntax.

```kairo
ffi "c++" import "my_code.hh";

fn main() {
    try {
        might_throw(true);
    } catch e: std::exception {
        std::println(f"Caught: {e.what()}")
    }
}
```

> [!NOTE]
> Unlike Kairo's [panic system](/docs/panic), the compiler cannot statically
> determine every exception type a C++ function might throw. A `catch` block that doesn't handle a thrown type
> will propagate the exception up the stack. If nothing catches it, the runtime calls `std::terminate`.

Throwing Kairo exceptions into C++ is not yet supported. Use error codes or return types
(e.g., `Panickable<T>`) for error signaling in the Kairo -> C++ direction.

---

## ABI Compatibility

Kairo emits object code conforming to the platform's native C++ ABI:

- **Unix-like systems:** Itanium C++ ABI
- **Windows:** Microsoft C++ ABI

This means Kairo `.o`/`.obj` files can be linked with object files from any ABI-compliant C++ compiler (GCC,
Clang, MSVC) without shims or translation layers. Name mangling, vtable layout, RTTI, and exception unwinding
tables all follow the platform convention.

`ffi "c++"` declarations use C++ mangling. `ffi "c"` declarations use C mangling (no decoration). This matches
the behavior of `extern "C++"` and `extern "C"` in C++.

---

## A Note on C++ Modules

C++20 named modules (`import std;`, `import my_module;`) are **not currently supported**. The interop layer
relies on header-based inclusion via Clang's preprocessor, and module interface deserialization (consuming
pre-compiled BMIs) is a future roadmap item.

Exporting Kairo code as a C++ module interface unit (`.cppm`) is also planned but not yet implemented.

**For now:** use header-based interop (`ffi "c++"` + `kcc`) for all cross-language boundaries.

# Calling C and C++ from Kairo

## Calling C/C++ from Kairo

Import a C or C++ header with the [`ffi` directive](/docs/language/imports/#ffi-header-imports). The compiler parses the header, extracts declarations, and makes them available as native Kairo symbols. No wrapper code is required.

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

> [!NOTE]
> `ffi "c++"` invokes the pinned Clang's frontend internally to parse the header. All exported declarations (functions, classes, enums, templates) become available in Kairo's scope with their original names and signatures. No code generation or binding step is visible to the user.

An imported function's default arguments are applied by C++, which can only leave out trailing arguments. Naming a later parameter while an earlier defaulted one is omitted is an error (SC107E); pass the earlier ones explicitly. See [Functions](/docs/language/functions-parameters/#defaults-on-imported-c-functions).

### Operators on C++ types

Using an operator on C++ types follows C++ lookup:

- **Member operators:** `a.operator+(b)`.
- **Free operators:** found by argument-dependent lookup in the operands' namespaces, across every header that reopens that namespace.
- **Hidden friends** (`friend bool operator==(...)` defined inside a class): found through either operand's class.
- **Operator templates:** chosen by C++'s partial ordering.
- **C++20 rewrites:** when an operand is a C++ type and no `!=` takes the operands, `a != b` is `!(a == b)`; `<` and the other relational operators fall back to `<=>` the same way. Kairo types keep Kairo's own rule: `!=` is derived from `op ==` only when the type declares no `op !=`. See [Derived comparisons](/docs/language/operator-overloading/#derived-comparisons).

Unary `*` on an imported C++ class calls its `operator*`, which is how C++ iterators and smart pointers are read.

### Argument conversions

C and C++ signatures are judged by Kairo's conversion rules, with one addition: a fixed-width integer argument widens into a `size_t`, `ptrdiff_t`, `uintptr_t` or `intptr_t` parameter, and a `usize`/`isize` argument widens into a fixed-width one, whenever that is lossless on every 32- and 64-bit target. `n: u32` passes to a `size_t` directly on 32- and 64-bit targets; `n: u64` needs `as usize`. See the [Conversion Lattice section 4.1](/docs/language/conversion-lattice/#41-the-cc-boundary).

### Tags and ordinary names

C and C++ keep struct, class, union and enum names (tags) apart from variables, functions and typedefs, so a header can declare both under one name. glibc does: `struct timezone` in `<sys/time.h>` and `extern long timezone` in `<time.h>`. As in C++, the plain name means the ordinary declaration:

```kairo
ffi "c++" import "time.h"
ffi "c++" import "sys/time.h"

fn example() {
    var west: i64 = timezone      // the variable
}
```

The struct is still the type of everything that uses it, such as `gettimeofday`'s second parameter. To name it yourself, declare it with a bodiless `ffi` struct, which refers to the header's `struct timezone` instead of declaring a new type:

```kairo
ffi "c++" import "time.h"
ffi "c++" import "sys/time.h"
ffi "c" struct timezone

fn now(tv: unsafe *timeval, tz: unsafe *timezone) -> i32 {   // the struct
    var west: i64 = timezone                                  // still the variable
    return gettimeofday(tv, tz)
}
```

In a type, `timezone` is then the struct; in an expression, it is still the variable. `class` and `union` work the same way. Without a matching struct in the imported headers, `ffi "c" struct T` is an ordinary forward declaration.

`typedef struct X X` is one type, not two names. Two different variables or typedefs under one name, which C++ only allows through inline namespaces, are an error where the name is used, not at the import: `ambiguous import: '{name}' names more than one non-function symbol` (R016E), with a note at each candidate.

---

## The `ffi` Keyword

`ffi` controls linkage and name mangling. It can be applied to individual declarations or to blocks.

```kairo
// C++ linkage: name mangling, overloading, classes, templates all permitted
ffi "c++" {
    fn compute(x: i32) -> i32 {
        return x + 1;
    }
}

// C linkage: no name mangling, same restrictions as extern "C" in C++
ffi "c" fn add(x: i32, y: i32) -> i32 {
    return x + y;
}
```

`ffi "c"` follows the same rules as `extern "C"` in C++: no classes, no overloading, no templates. `ffi "c++"` follows the same rules as `extern "C++"`: full C++ feature set, Itanium or MSVC mangling depending on the target.

Name mangling is covered in [ABI Contract & Verification](/docs/language/c-cpp-abi/#name-mangling).

---

## Namespace Mapping

`std` means different things on the two sides of the boundary. The mapping is fixed:

| Spelling | On the Kairo side | On the C++ side |
|---|---|---|
| `std::` | Kairo's standard library | C++'s standard library |
| `cxx::std::` | C++'s standard library | - |
| `kairo::` | - | Kairo's own namespace, including its standard library |

From Kairo, the C++ standard library is always reached through `cxx::std::`:

```kairo
ffi "c++" import <vector>;

fn example() {
    var v: cxx::std::vector<i32>
    v.push_back(42)
}
```

Kairo's standard library lands inside `namespace kairo`, which is why a C++ translation unit sees Kairo's library under `kairo::` and its own under the unqualified `std::` it already uses. Nothing is renamed on the C++ side. Your own code lands in its module's namespace, the files you compile included, or, for a file outside every search directory, in a namespace named after the file's stem. See [Modules](/docs/language/modules/#module-paths-are-c-namespaces).

> [!NOTE]
> `inline "c++"` blocks are not supported from Stage 1 onward. Use `ffi "c++"` to import declarations and call them as ordinary Kairo symbols. The older `__inline_cpp("...")` form is likewise removed.

---

## Inline ASM

For cases where you need to embed hardware-specific instructions, use `inline "asm"` blocks. Kairo uses the extended assembly syntax (outputs, inputs, and clobbers) to allow safe interaction between assembly and Kairo variables.

```kairo
fn get_timestamp() -> u64 {
    var low: u32
    var high: u32

    // The syntax follows: "instruction" : outputs : inputs : clobbers
    unsafe {
        inline "asm" {
            "rdtsc"
            : "=a"(low), "=d"(high)
            :
            :
        }
    }

    return (high as u64 << 32) | (low as u64)
}

fn syscall_example(fd: i32, buf: *u8, len: usize) -> isize {
    var ret: isize
    unsafe {
        inline "asm" volatile {
            "syscall"
            : "=a"(ret)
            : "a"(1), "D"(fd), "S"(buf), "d"(len)
            : "rcx", "r11", "memory"
        }
    }
    return ret
}
```

### Constraints and Safety

- **Volatile**: Use `inline "asm" volatile` if the assembly has side effects that the optimizer might otherwise remove (like a syscall or hardware port I/O).
- **Clobbers**: Always list registers modified by the assembly (like `memory` or specific registers) to prevent the [Tether analysis](/docs/language/tether-internals/#cc-interop) and LLVM from making incorrect assumptions about the state of the machine.
- **Unsafe**: Assembly code is inherently unsafe and should be wrapped in an [`unsafe` block](/docs/language/unsafe/#unsafe-blocks) to indicate that the programmer is responsible for ensuring the correctness of the assembly.

---

## Pointers and References

Kairo's [pointer model](/docs/language/pointers/) distinguishes safe pointers (`*T`, non-nullable, tracked) from raw pointers (`unsafe *T`, no tracking). Passing any pointer or reference across the FFI boundary requires explicit [`unsafe` context](/docs/language/unsafe/#when-unsafe-blocks-are-required) because the compiler cannot enforce safety guarantees on the C/C++ side.

C++ reference *parameters* (`T&`, `const T&`, `T&&`) are not pointers. They map to Kairo's parameter modes (`@inout x: T`, `x: T`, `@move x: T`). See [Parameter passing modes](/docs/language/functions-parameter-modes/).

### Calls that return a reference

A call that returns a C++ reference, such as `v.at(i)`, `*p`, or `cout << x`, is usable directly as an operand and as the target of an assignment:

```kairo
ffi "c++" import <vector>;

fn main() {
    var v: cxx::std::vector<i32>
    v.push_back(1)

    v.at(0) = 3             // assign through int&
    v.at(0) += 2            // compound assignment
    var x = v.at(0) + 1     // operand
}
```

See [Reference returns from C++](/docs/language/functions-parameter-modes/#reference-returns-from-c) for how these calls are typed.

### Safe variable, unsafe pass

```kairo
ffi "c++" import "my_code.hh";

fn main() {
    var x = 41

    // compile error: cannot pass reference to C function without unsafe block
    // add_one(&x)

    unsafe {
        add_one(unsafe &x)  // strips tracking; caller owns the memory contract
    }

    // for calling c++ with pointers and back, you must use unsafe blocks;
    // shorthand syntax is not allowed: `unsafe add_one(unsafe &x)` is a compile error

    std::println(f"x = {x}")  // x = 42
}
```

`unsafe &` creates a [raw pointer](/docs/language/pointers/#creating-raw-pointers) from a safe binding. The compiler relinquishes tracking for that pointer, and the caller is responsible for lifetime and aliasing correctness.

### Raw pointer from the start

If the value will be passed to C/C++ repeatedly, allocate it as a raw pointer upfront:

```kairo
ffi "c++" import "my_code.hh";

fn main() {
    var x: unsafe *i32 = @create i32(41)
    add_one(x)  // already unsafe, no block needed
    std::println(f"x = {*x}")  // x = 42
}
```

> [!WARNING]
> `unsafe *T` pointers can be null. Dereferencing a null `unsafe *T` is undefined behavior. The compiler will not insert a null check.

### Strings and `const char*`

C's `char` is [`std::c_char`](/docs/language/primitives/#cs-char-stdc_char), so a C++ `const char*` is `*const c_char` in Kairo, and back: a function returning one can be stored, compared with `&null`, indexed and passed on to any C or C++ parameter of that type. `char`, `signed char` and `unsigned char` are three types, as in C++, so a header that overloads on them gives three Kairo overloads (`c_char`, `i8`, `u8`).

A Kairo [`string`](/docs/language/primitives/#strings) stores UTF-8 bytes (`data` is `*const u8`) with a NUL after the last one, so its bytes are a C string once the pointer is reinterpreted. Bytes and C chars are unrelated types, so that is an `as unsafe *` cast inside an `unsafe` block ([pointer cast rules](/docs/language/casting/#pointer-cast-rules)); passing the `*u8` itself is an error whose fix-it inserts the cast:

```kairo
import std::c_char
ffi "c" import "string.h"

fn main() {
    var s = "hello"
    unsafe {
        var n = strlen(s.data as unsafe *const c_char)   // 5
        // strlen(s.data)   // error SC063E: a C string is '*const c_char'; fix-it: ` as unsafe *const c_char`
    }
}
```

A `*const c_char` in an f-string prints as a pointer (`const c_char @ 0x...`), like any pointer: there is no C-string formatter yet. A `string.c_str()` method is planned.

---

## Templates and Concepts

Kairo [generics](/docs/language/generics/) and C++ templates are interchangeable across the boundary. A C++ concept can constrain a Kairo generic parameter, and a Kairo generic type can satisfy a C++ concept.

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

`T impl Addable` in Kairo maps directly to `Addable T` in the generated C++. The constraint is preserved across the boundary, not erased.

### Template arguments, pointers and forwarding

Non-type template arguments are written as Kairo values: `cxx::std::array<i32, 4>`, `llvm::SmallVector<*Node, 8>`, `Flag<true>`. An `eval` constant or arithmetic over constants works (`array<i32, N * 2>`). The argument's identity is its integer, so `array<i32, N>` with `eval N: usize = 4` and `array<i32, 4>` are the same type.

A container of Kairo pointers keeps the pointer kind you wrote: `cxx::std::vector<*Node>` hands out `*Node`, `vector<unsafe *Node>` hands out `unsafe *Node`. Both are `std::vector<Node*>` in C++.

Any Kairo type with a C++ spelling may be an argument of an imported class template: builtins, pointers, records and generic records, tuples, plain enums, ADT enums (generic or not), and nullables (`vector<i32?>`, `vector<*Node?>`). The instance's members read back as the Kairo types, so `push_back(null)`, `if x? { ... }`, `v[0] ?? d`, `v[0] = null` and `match` on an element work as for any value. Not yet: a function type (`fn(i32) -> i32`) as an element (calling `v[0](3)` is rejected).

A C++ function template with a forwarding pack (`template <class... Args> void emplace_back(Args&&... args)`) takes any number of arguments; each is passed as written and C++ deduces its reference kind. A `const Ts&...` pack takes any argument, a `Ts&...` pack only variables (lvalues).

Overloaded C++ function templates are chosen as C++ chooses them, SFINAE included: an overload whose `enable_if` condition, `requires` clause, `decltype(...)` return type or `void_t` test fails for the arguments is not a candidate. So `cxx::std::make_unique<i32>(9)`, `make_unique<T[]>(n)` (through a header alias such as `using IntArr = int[];`, since `[T;]` in Kairo is a slice) and `make_shared` work, and `v.assign(n, x)` on a `cxx::std::vector` takes the count overload while `v.assign(a.begin(), a.end())` takes the iterator one. When every overload is removed, the error lists each with C++'s reason (`requirement 'std::is_integral_v<Pair>' was not satisfied`). Only the generic arguments you write are passed (`make_unique<i32>`); C++ deduces the rest from the arguments, so a variable passed through `Args&&` stays a reference to that variable. Inside a generic function, a call whose choice depends on `T` is decided for each instantiation.

A C++ method with a ref-qualifier is called only on the object it accepts: `int q() &` on a variable, `int q() &&` on a temporary (`make().q()`), and with both declared a temporary calls the `&&` one. A method without a ref-qualifier can be called on either.

## See also

- [C & C++ Interoperability](/docs/language/c-cpp/)
- [kairo, kcc & Cross-compilation](/docs/language/c-cpp-toolchain/)
- [Using Kairo in C++](/docs/language/c-cpp-exposing/)
- [ABI Contract & Verification](/docs/language/c-cpp-abi/)
- [Pointers](/docs/language/pointers/)
- [Unsafe](/docs/language/unsafe/)
- [Parameter Passing Modes](/docs/language/functions-parameter-modes/)
- [Generics](/docs/language/generics/)

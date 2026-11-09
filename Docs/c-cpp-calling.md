# Calling C and C++ from Kairo

## Calling C/C++ from Kairo

Import a C or C++ header with the [`ffi` directive](/docs/language/imports/#ffi-header-imports). The compiler parses the header, extracts declarations, and makes them available as native Kairo symbols. No wrapper code is required.

```kairo
// main.k
ffi "c++" import "my_code.hh";

fn main() {
    var obj = MyClass("Kairo")
    obj.greet()
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
    MyClass(const char *name) : name(name) {}
    void greet() const { std::cout << "name = " << name << std::endl; }
private:
    std::string name;
};

inline void my_function(int x) {
    std::cout << "Hello from C++! x = " << x << std::endl;
}
```

Build and run:

```sh
kairo main.k -o main
./main
```

```
name = Kairo
Hello from C++! x = 42
```

> [!NOTE]
> `ffi "c++"` invokes the pinned Clang's frontend internally to parse the header. All exported declarations (functions, classes, enums, templates) become available in Kairo's scope with their original names and signatures. No code generation or binding step is visible to the user.

Kairo, not clang, decides which declaration a call means. Overload ranking, argument-dependent lookup, template specialization selection and `requires` / SFINAE constraints on imported declarations are all resolved by Kairo's own semantic analysis, with C++'s rules (so a Kairo and a C++ caller of the same overload set get the same answer). Clang is asked for exactly two things: to complete the instance of an imported class template (`cxx::std::vector<i32>` gets its members from clang's instantiation), and to deduce the template arguments of an imported function-template candidate. Everything it is asked is an answer about one declaration, never a choice between several.

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

`ffi` controls linkage and name mangling. It is written on a declaration.

> [!NOTE]
> Not yet: the block form `ffi "c++" { fn ... }` type-checks but stops code generation with an internal compiler error (`EmitIR: decl kind FFIBlockDecl has no body to emit`). Write `ffi "c++"` or `ffi "c"` on each declaration.

```kairo
// C++ linkage: name mangling, overloading, classes, templates all permitted
ffi "c++" fn compute(x: i32) -> i32 {
    return x + 1;
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
ffi "c++" import "vector"

fn example() {
    var v: cxx::std::vector<i32>
    v.push_back(42)
}
```

Kairo's standard library lands inside `namespace kairo`, which is why a C++ translation unit sees Kairo's library under `kairo::` and its own under the unqualified `std::` it already uses. Nothing is renamed on the C++ side. Your own code lands in its module's namespace, the files you compile included, or, for a file outside every search directory, in a namespace named after the file's stem. See [Modules](/docs/language/modules/#module-paths-are-c-namespaces).

> [!NOTE]
> `inline "c++"` blocks are not supported. Use `ffi "c++"` to import declarations and call them as ordinary Kairo symbols. The older `__inline_cpp("...")` form is likewise removed.

---

## Inline ASM

For cases where you need to embed hardware-specific instructions, use `inline "asm"` blocks. Kairo uses the extended assembly syntax (outputs, inputs, and clobbers) to allow safe interaction between assembly and Kairo variables.

> [!NOTE]
> Not yet: an `inline "asm"` block parses and type-checks, but code generation does not emit it. A program containing one stops with an internal compiler error (`EmitIR: inline foreign block; not emitted yet`). The examples below show the intended syntax.

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
        inline "asm" {
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

- **Volatile**: the `volatile` modifier (`inline "asm" volatile { ... }`), meant for assembly with side effects the optimizer might otherwise remove, is not accepted yet: the parser rejects it (S056E).
- **Clobbers**: Always list registers modified by the assembly (like `memory` or specific registers) to prevent the [Tether analysis](/docs/language/tether-internals/#cc-interop) and LLVM from making incorrect assumptions about the state of the machine.
- **Unsafe**: Assembly code is inherently unsafe and should be wrapped in an [`unsafe` block](/docs/language/unsafe/#unsafe-blocks) to indicate that the programmer is responsible for ensuring the correctness of the assembly.

---

## Pointers and References

Kairo's [pointer model](/docs/language/pointers/) distinguishes safe pointers (`*T`, non-nullable, tracked) from raw pointers (`unsafe *T`, no tracking). Passing any pointer or reference across the FFI boundary requires explicit [`unsafe` context](/docs/language/unsafe/#when-unsafe-blocks-are-required) because the compiler cannot enforce safety guarantees on the C/C++ side.

C++ reference *parameters* (`T&`, `const T&`, `T&&`) are not pointers. They map to Kairo's parameter modes (`@inout x: T`, `x: T`, `@move x: T`). See [Parameter passing modes](/docs/language/functions-parameter-modes/).

So an argument to a non-const `T&` parameter is marked `&x`, as for any `@inout` parameter, and is passed by reference: nothing is copied or moved, and an object of a class derived from `T` binds too. A bare `x` is an error (SC097E) with a fix-it that adds the `&`. A safe `&x` is the marker, so `pick(&x)` calls `pick(int&)` over `pick(int*)`; `pick(unsafe &x)` passes the raw pointer and calls `pick(int*)`.

```kairo
ffi "c++" import "sstream"

var f = cxx::std::istringstream(cxx::std::string("a\nb\n"))
var line = cxx::std::string()
while cxx::std::getline(&f, &line) as bool {   // istream&: f is borrowed, not moved
    // ...
}
```

### Function objects

An object of a C++ class with `operator()` (a lambda's closure type, `std::function`, `llvm::function_ref`) is called as `f(args)`. The call is resolved over the class's `operator()` overloads as C++ resolves it: a const object picks the const overload, and the arguments pick among the rest. The object itself is not moved by the call. Through a pointer, call `(*p)(args)`; a pointer to a function object is not itself callable.

### Calls that return a reference

A call that returns a C++ reference, such as `v.at(i)`, `*p`, or `cout << x`, is usable directly as an operand and as the target of an assignment:

```kairo
ffi "c++" import "vector"

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
import std::io
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

    io::println(f"x = {x}")  // x = 42
}
```

`unsafe &` creates a [raw pointer](/docs/language/pointers/#creating-raw-pointers) from a safe binding. The compiler relinquishes tracking for that pointer, and the caller is responsible for lifetime and aliasing correctness.

### Heap value, raw pass

`@create` returns a safe `*T`, never a raw one, so `var x: unsafe *i32 = @create i32(41)` is an error (SC028E). A heap value passed to C/C++ is converted at the call, inside `unsafe`:

```kairo
import std::io
ffi "c++" import "my_code.hh";

fn main() {
    var *x = @create i32(41)
    unsafe { add_one(x as unsafe *i32) }
    io::println(f"x = {*x}")  // x = 42
}
```

Passing the safe `*i32` straight to an `int*` parameter is a no-matching-overload error (SC063E).

> [!WARNING]
> `unsafe *T` pointers can be null. Dereferencing a null `unsafe *T` is undefined behavior. The compiler will not insert a null check.

### Strings and `const char*`

C's `char` is [`std::c_char`](/docs/language/primitives/#cs-char-stdc_char), so a C++ `const char*` is `*const c_char` in Kairo, and back: a function returning one can be stored, compared with `&null`, indexed and passed on to any C or C++ parameter of that type. `char`, `signed char` and `unsigned char` are three types, as in C++, so a header that overloads on them gives three Kairo overloads (`c_char`, `i8`, `u8`). Likewise `wchar_t`, `char16_t` and `char8_t` are `c_wchar`, `c_char16` and `c_char8`, so `f(wchar_t)` beside `f(int)` is two overloads, and a `const wchar_t*` is `*const c_wchar`.

A string **literal** passed to an imported C or C++ function's `const char*` parameter (`*const c_char`, safe or `unsafe`) is the C string itself: the compiler passes the literal's static, NUL-terminated bytes, and no `string` is made. The same holds for a `const unsigned char*` (`*const u8`) parameter and for the `...` of a variadic C function such as `printf`. The parameter must be `const`: a literal's bytes are read-only, so a `char*` parameter does not take one.

Any other [`string`](/docs/language/primitives/#strings) passes its bytes with `s.c_str()`, which returns `unsafe *const c_char`. It costs nothing: a Kairo string keeps a NUL after its last byte, a literal's and an owned string's alike. The pointer is valid until the string is next changed or destroyed. Passing the `string` itself is an error whose fix-it inserts `.c_str()`:

```kairo
ffi "c" import "string.h"
ffi "c" import "stdlib.h"
ffi "c" import "stdio.h"

fn main() {
    var n = strlen("hello")                 // 5: the literal is the C string
    var unsafe *home = getenv("HOME")
    printf("%s %zu\n", "count", n)          // literals through C's `...` too

    var s = "hello"
    s += ", world"
    var m = strlen(s.c_str())               // 12
    // strlen(s)          // error SC063E: a string other than a literal passes its bytes with '.c_str()'; fix-it: `.c_str()`
    // printf("%s\n", s)  // error: a 'string' cannot pass through C's '...'; fix-it: `.c_str()`
}
```

The `string`'s bytes are also `data` (`*const u8`). Bytes and C chars are unrelated types, so passing `data` to a `const char*` parameter needs an `as unsafe *const c_char` cast inside an `unsafe` block ([pointer cast rules](/docs/language/casting/#pointer-cast-rules)); passing the `*u8` itself is an error whose fix-it inserts the cast.

A `*const c_char` in an f-string prints as a pointer (`const c_char @ 0x...`), like any pointer: there is no C-string formatter yet.

### Function pointers and callbacks

A C or C++ function pointer type (`int (*)(int)`) imports as the raw Kairo type `unsafe fn(i32) -> i32`. A named Kairo function or a closure that captures nothing can be passed there. A closure that captures, or a `fn(...)` value (which may hold one), is a compile error, because C has nowhere to keep the captured variables:

```kairo
ffi "c" import "callbacks.h"     // int c_apply(int (*f)(int), int x);

fn twice(x: i32) -> i32 { return x * 2 }

fn main() -> i32 {
    var k = 3
    var a = c_apply(twice, 4)                                   // 8
    var b = c_apply(fn (v: i32) -> i32 { return v + 1 }, 4)     // 5
    // c_apply(fn (v: i32) -> i32 { return v * k }, 4)   // error: the closure captures 'k'
    return a + b
}
```

---

## Templates and Concepts

Kairo [generics](/docs/language/generics/) and C++ templates meet in both directions. Calling a constrained C++ template from Kairo works; bounding a Kairo generic by a C++ concept does not compile yet.

A C++20 concept imports as a constraint-only interface, and a function template constrained by it imports as a generic:

```cpp
// concept.h
#pragma once
template <typename T>
concept Addable = requires(T a, T b) { a + b; };

template <Addable T>
T add_twice(T a) { return a + a; }
```

```kairo
import std::io
ffi "c++" import "concept.h"

fn main() -> i32 {
    var x: i32 = 21
    io::println(f"{add_twice(x)}")      // 42
    return 0
}
```

> [!NOTE]
> Not yet: a Kairo generic bounded by an imported concept (`fn <T impl Addable> add(a: T, b: T) -> T { return a + b }`) is rejected with R025E, because the concept's `requires` expression grants no operations on `T`. A bound whose body does not use `T`'s operations type-checks but fails in code generation (CL001E, `no member named '<header>' in the global namespace`). A bound on a Kairo interface works: `fn <T impl Shape> twice(a: T)` becomes a `requires` clause over the concept the compiler emits for `Shape`, and a C++ call with a type that does not satisfy it fails with `'Bad' does not satisfy 'Shape_c'`. A bound on a generic class or struct is not translated (see [Generics](/docs/language/c-cpp-exposing/#generics)).

### Template arguments, pointers and forwarding

Non-type template arguments are written as Kairo values: `cxx::std::array<i32, 4>`, `llvm::SmallVector<*Node, 8>`, `Flag<true>`. An `eval` constant or arithmetic over constants works (`array<i32, N * 2>`). The argument's identity is its integer, so `array<i32, N>` with `eval N: usize = 4` and `array<i32, 4>` are the same type.

A container of Kairo pointers keeps the pointer kind you wrote: `cxx::std::vector<*Node>` hands out `*Node`, `vector<unsafe *Node>` hands out `unsafe *Node`. Both are `std::vector<Node*>` in C++.

Any Kairo type with a C++ spelling may be an argument of an imported class template: builtins, pointers, records and generic records, tuples, plain enums, ADT enums (generic or not), and nullables (`vector<i32?>`, `vector<*Node?>`). The instance's members read back as the Kairo types, so `push_back(null)`, `if x? { ... }`, `v[0] ?? d`, `v[0] = null` and `match` on an element work as for any value. A written `fn(i32) -> i32` as a template argument is the C++ function type `i32(i32)`, so `function_ref<fn(i32) -> bool>(closure)` names the same instance as a C++ `function_ref<bool(int)>` parameter; a raw `unsafe fn(i32) -> i32` is the function pointer `R(*)(A)`, a different instance. Not yet: calling a function-type element (`v[0](3)` is rejected).

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

# C & C++ Interoperability

Kairo provides zero-overhead, bidirectional interoperability with C and C++. There is no serialization layer, no binding generator, and no runtime bridge. Kairo emits ABI-compatible object code and consumes C/C++ headers directly.

The guarantee that makes this work is not a clever calling convention. It is that **Kairo ships its own pinned Clang, and every translation unit on both sides of the boundary goes through it.** The failure mode that breaks C++ interop for most languages (header parsed by compiler A, code compiled by compiler B, ABI mismatch discovered at runtime) is designed out rather than mitigated.

This page covers the toolchain model, calling C/C++ from Kairo, exposing Kairo to C/C++, inline assembly, pointer and reference passing, templates and concepts, allocators and ownership, the exception model, and the ABI contract enforced at link time.

## In this section

- [kairo, kcc & Cross-compilation](/docs/language/c-cpp-toolchain/)
- [Calling C and C++ from Kairo](/docs/language/c-cpp-calling/)
- [Using Kairo in C++](/docs/language/c-cpp-exposing/)
- [Allocators & Ownership](/docs/language/c-cpp-memory/)
- [Exceptions & Panics](/docs/language/c-cpp-exceptions/)
- [ABI Contract & Verification](/docs/language/c-cpp-abi/)

---

## Coverage Matrix

What crosses the boundary, feature by feature. Each row is rated in two directions:

- **C++ → Kairo**: Kairo code uses the C or C++ feature, through an [`ffi` import](/docs/language/imports/#ffi-header-imports).
- **Kairo → C++**: C or C++ code uses the Kairo feature, through [`#include "x.k"`](/docs/language/c-cpp-toolchain/#how-kcc-works) or a [generated header](/docs/language/c-cpp-exposing/#headers).

Each direction cell holds one of:

- ✅ works
- ◐ partial: the Notes say what does not work yet
- ❌ not supported, or not compiled yet
- — n/a: the feature exists on one side only; nothing to rate in this direction
- ? not documented yet

**Kairo-only** and **C++-only** in the Notes mark a feature with no counterpart on the other side, and say what it becomes across the boundary. "Not yet" follows [Implementation Status](/docs/status/#not-compiled-yet).

| Feature | Kairo uses it from C/C++ (C++ → Kairo) | C/C++ uses it from Kairo (Kairo → C++) | Notes |
|---|---|---|---|
| **Toolchain and linkage** | | | |
| Using the other side's declarations | ✅ | ◐ | C and C++ headers import with [`ffi "c"` / `ffi "c++"`](/docs/language/imports/#ffi-header-imports); Objective-C headers cannot be imported yet. C++ and Objective-C++ files use Kairo through `#include "x.k"` ([kcc](/docs/language/c-cpp-toolchain/#how-kcc-works)) or [`--emit-headers`](/docs/language/c-cpp-exposing/#headers); plain C and Objective-C files cannot include a `.k` yet ([Status](/docs/status/#not-in-this-release)) |
| C and C++ linkage (`ffi "c"`, `ffi "c++"`) | ✅ | ✅ | `ffi "c"` follows `extern "C"` rules: no classes, overloading or templates. See [The `ffi` keyword](/docs/language/c-cpp-calling/#the-ffi-keyword) |
| Name mangling and platform ABI | ✅ | ✅ | Itanium or MSVC, taken from Clang's own mangler; vtables, RTTI and struct layout follow the platform. See [ABI Compatibility](/docs/language/c-cpp-abi/#abi-compatibility) |
| Layout-affecting C++ flags (`-fno-rtti`, `-fshort-enums`, packing) | ❌ | — | **C++-only.** Rejected in any translation unit that touches Kairo types. See [Layout-affecting](/docs/language/c-cpp-toolchain/#3-layout-affecting) |
| Namespaces and modules | ✅ | ✅ | A module path is its C++ namespace, and `module` blocks are namespaces. C++'s `std` is `cxx::std::` in Kairo; Kairo's library is `kairo::` in C++. A module that only re-exports has no header. See [Namespace Mapping](/docs/language/c-cpp-calling/#namespace-mapping) and [Modules](/docs/language/modules/#module-paths-are-c-namespaces) |
| Argument-dependent lookup | ◐ | — | **C++-only.** Operators are always found by ADL. An unqualified call of a function found only by ADL is not found unless a Kairo function of that name is visible ([Status](/docs/status/#not-compiled-yet)); qualify it |
| C++20 named modules (`import std;`) | ❌ | ❌ | Neither consumed nor produced. See [A Note on C++ Modules](#a-note-on-c-modules) |
| C and C++ preprocessor macros | ◐ | — | **C++-only.** Macros are expanded inside the imported headers before Kairo sees the declarations. [`defined!`](/docs/language/macros-builtin/#conditional) sees the target's predefined macros and every macro the file's `ffi` headers define |
| A `#define` constant used as a Kairo value | ? | — | Whether an object-like macro (`#define N 4`) can be named in Kairo code is not documented; `defined!` is the documented way to test one |
| Kairo macros (`macro m!`) | — | — | **Kairo-only.** Token substitutions expanded before parsing; C++ gets only the code they expand to. See [Macros](/docs/language/macros/) |
| Inline C++ (`inline "c++"`, `__inline_cpp`) | ❌ | — | Removed from Stage 1. Import the declarations with `ffi "c++"` instead. See [Namespace Mapping](/docs/language/c-cpp-calling/#namespace-mapping) |
| Inline assembly (`inline "asm"`) | — | — | **Kairo-only** syntax, in an `unsafe` block, with GCC-style outputs, inputs and clobbers. A function that uses it is called like any other. See [Inline ASM](/docs/language/c-cpp-calling/#inline-asm) |
| **Types** | | | |
| Integers, floats, `bool` | ✅ | ✅ | Fixed C++ equivalents (`i32` is `std::int32_t`, `f64` is `double`; `i64` is the target's `int64_t`). Fixed-width integers widen into `size_t` / `ptrdiff_t` parameters where that is lossless. See [Primitives](/docs/language/primitives/) and [Argument conversions](/docs/language/c-cpp-calling/#argument-conversions) |
| Characters (`char`, C's `char`, `byte`) | ✅ | ✅ | C's `char` is [`std::c_char`](/docs/language/primitives/#cs-char-stdc_char), a third type beside `i8` and `u8`. Kairo's `char` is `char32_t`, `byte` is `std::byte` |
| C bit-fields | ✅ | — | **C++-only.** Read and written from Kairo; a write wraps at the field's width. See [Primitives](/docs/language/primitives/) |
| Structs | ✅ | ✅ | C layout and calling convention. In C++ a Kairo struct is a plain aggregate with public fields. A bodiless `ffi "c" struct T` names a header's tagged struct ([Tags and ordinary names](/docs/language/c-cpp-calling/#tags-and-ordinary-names)). See [Structs](/docs/language/structures/) |
| Unions | ✅ | ✅ | Untagged, laid out by the C++ ABI. See [Unions](/docs/language/unions/) |
| Plain enums | ✅ | ✅ | `enum Dir derives u8` is `enum class Dir : std::uint8_t`. An imported C or C++ enum is always [open](/docs/language/enums-plain/#closed-and-open-enums). See [Enums](/docs/language/enums/) |
| ADT enums (variants with payloads) | — | ◐ | **Kairo-only.** To C++, a class holding the tag and the payload storage: it can be held, passed and returned, and built and inspected through Kairo functions. No C++ API over the variants is documented. It has no default value, so `map::operator[]` with one as the element fails ([Status](/docs/status/#not-compiled-yet)). See [ADT Enums](/docs/language/enums-adt/#memory-layout) |
| Tuples | — | ✅ | **Kairo-only.** A named struct in a reserved namespace, named after its element types, so every translation unit agrees on it; C++ can name, return and specialize on it. C++'s `std::tuple` / `std::pair` are ordinary class templates. See [Tuples across the boundary](/docs/language/c-cpp-exposing/#tuples-across-the-boundary) |
| Nullables (`T?`) | — | ◐ | **Kairo-only.** `::builtin::Nullable<T>`, with `null` as `::builtin::null`; `*T?` is pointer-sized, and a closed enum's `E?` is the enum's size. Not yet: `bool?` is two bytes, not one ([Status](/docs/status/#not-compiled-yet)). A nullable can be a C++ template argument (`vector<i32?>`). See [Nullables Across the Boundary](/docs/language/c-cpp-exposing/#nullables-across-the-boundary) |
| Pointers (`*T`, `unsafe *T`) | ✅ | ✅ | A safe `*T` is `T*` in C++. Passing a pointer to a C or C++ function needs an [`unsafe` block](/docs/language/unsafe/#unsafe-blocks); `unsafe &x` makes a raw pointer from a safe binding, and an `unsafe *T` is C's `T*`. A C++ container keeps the pointer kind written (`vector<*Node>`). See [Pointers and References](/docs/language/c-cpp-calling/#pointers-and-references) |
| C++ references (`T&`, `const T&`, `T&&`) | ✅ | ✅ | Reference parameters are the [parameter modes](/docs/language/functions-parameter-modes/) `@inout x: T`, `x: T` and `@move x: T`, in both directions. A call returning a reference is usable as an operand and as an assignment target ([Reference returns](/docs/language/functions-parameter-modes/#reference-returns-from-c)). `const T&&` can be called, not declared |
| C++ smart pointers (`unique_ptr`, `shared_ptr`, `weak_ptr`) | ◐ | ? | Usable as imported class templates (`cxx::std::make_unique<i32>(9)`). Their automatic mapping to `std::Unique` / `Shared` / `Weak` ([Smart Pointer Promotion](/docs/language/pointers/#smart-pointer-promotion)) is part of [Tether](/docs/language/tether-internals/#cc-interop), which is not in this release. How Kairo's own smart pointers look to C++ is not documented |
| Function pointers | ✅ | ✅ | `int (*)(int)` imports as `unsafe fn(i32) -> i32` and takes a named function or a closure that captures nothing. A Kairo `unsafe fn` is a plain C function pointer, and so is every `fn` parameter of an `ffi "c"` function. See [Function pointers and callbacks](/docs/language/c-cpp-calling/#function-pointers-and-callbacks) |
| Closures and `fn` values | ? | ◐ | A `fn(i32) -> i32` value is `::__kairo_fn<std::int32_t(std::int32_t)>` in C++. A capturing closure, or any `fn` value, passed where a C function pointer is expected is a compile error. Not yet: generic closures. As a C++ template argument a written `fn(A) -> R` is the C++ function type `R(A)` (`function_ref<bool(int)>`), while a raw `unsafe fn(A) -> R` is the pointer `R(*)(A)`. Passing a C++ lambda or `std::function` into Kairo is not documented. See [Closures](/docs/language/closures/) |
| Arrays (`[T; N]`, C arrays) | ? | ? | Not documented. `cxx::std::array<i32, 4>` works as an imported template. See [Collections](/docs/language/collections/#arrays-t-n) |
| Slices, vectors, maps, sets | — | ? | **Kairo-only.** Their C++ form is not documented. Not yet: vector literals do not link, set and map literals are not compiled. C++ containers are used through `cxx::std::`. See [Collections](/docs/language/collections/) |
| Strings | ◐ | ◐ | A `const char*` is `*const c_char`. A string literal is a C string at a `const char*` parameter (and through C's `...`); any other Kairo `string` passes `s.c_str()` ([Strings and `const char*`](/docs/language/c-cpp-calling/#strings-and-const-char)). `std::string` is an imported class. To C++, a Kairo `string` is a class, but its C++ API is not documented |
| f-strings | — | — | **Kairo-only.** A `*const c_char` prints as a pointer: there is no C-string formatter yet. See [Status](/docs/status/#not-compiled-yet) |
| Type aliases | ✅ | ✅ | C and C++ typedefs and `using` aliases import (`typedef struct X X` is one type). A Kairo member `type` alias is a C++ member `using` at the same access; top-level aliases are not documented. See [Type Aliases](/docs/language/type-aliases/) |
| **Functions** | | | |
| Functions and methods | ✅ | ✅ | A Kairo method in the class body is a C++ member function. See [What a Kairo declaration looks like in C++](/docs/language/c-cpp-exposing/#what-a-kairo-declaration-looks-like-in-c) |
| Overloading | ✅ | ✅ | An imported overload set is ranked as C++ ranks it, parameter modes included; a header that overloads `f(T)` against `f(const T&)` is an error at the import. See [Overloading](/docs/language/functions-overloading/) |
| Default arguments | ✅ | ? | C++ applies an imported function's defaults, so only trailing arguments can be left out ([SC107E](/docs/language/functions-parameters/#defaults-on-imported-c-functions)). Whether a Kairo default reaches C++ callers is not documented |
| Named arguments | — | — | **Kairo-only.** Work on imported functions, but cannot skip an earlier defaulted parameter. See [Named arguments](/docs/language/functions-parameters/) |
| C variadic functions (`...`) | ✅ | ? | Callable from Kairo (`printf`). Kairo can declare C-variadic functions, but how C sees them is not documented |
| Variadic templates and packs | ✅ | ? | A C++ forwarding pack (`Args&&...`) takes any number of arguments ([Template arguments](/docs/language/c-cpp-calling/#template-arguments-pointers-and-forwarding)). The C++ form of Kairo's `...xs: T` (a slice) and of [generic variadic functions](/docs/language/functions-parameters/#generic-variadic-functions) is not documented |
| `where` dispatch | — | ✅ | **Kairo-only.** Each group is one C++ function under its public name; the candidates stay private. See [where](/docs/language/where/) |
| Function hints (`@hot_path`, `@cold_path`, `@pure`, `@no_inline`, `fn f() const`) | — | ✅ | **Kairo-only.** Emitted as `[[gnu::hot]]`, `[[gnu::cold]]`, `[[gnu::pure]]`, `__attribute__((noinline))`, `[[gnu::const]]`. See [Function hints](/docs/language/attributes/#function-hints) |
| Calling conventions (`@preserve_most`, `@preserve_all`, `@preserve_none`) | — | ❌ | **Kairo-only.** Never on a function C or C++ can see (SC136E): only `priv` and local functions. See [Calling conventions](/docs/language/attributes/#calling-conventions) |
| `eval` (compile-time) | ? | ✅ | An imported `eval` constant is a compile-time constant to C++ code that includes the module, and an `eval` value is a valid C++ template argument (`array<i32, N * 2>`). Using a C++ `constexpr` / `consteval` in Kairo's `eval` is not documented. See [Eval](/docs/language/eval/) |
| Global and `static` variables | ✅ | ✅ | C and C++ globals import (glibc's `timezone`). A namespace-scope `static const` is a C++ `const` variable, a class member a `static const` data member. See [Static Variables](/docs/language/variables/#static-variables) |
| **Generics** | | | |
| Templates and generics | ◐ | ✅ | Imported templates take Kairo types and values as arguments, and are chosen as C++ chooses them, SFINAE included. Not yet: an imported template used over a generic Kairo function's own `T`, two pointer flavours of one element type, a defaulted non-type parameter that depends on an earlier one ([Status](/docs/status/#not-compiled-yet)). Kairo generics are C++ templates, bodies included. See [Templates and Concepts](/docs/language/c-cpp-calling/#templates-and-concepts) and [Generics](/docs/language/c-cpp-exposing/#generics) |
| C++ concepts and Kairo `impl` bounds | ◐ | ◐ | A C++ concept imports as a constraint-only interface, usable as a Kairo bound; a concept-constrained template imports as a generic. Not yet: an overload set told apart by a concept that calls a method of a Kairo class you pass ([Status](/docs/status/#not-compiled-yet)). A Kairo interface is a C++ concept, and an `impl` bound on a generic function or method is a `requires` clause; a bound on a generic class or struct is not translated, so a bad C++ instance fails inside the member that needs it. See [Templates and Concepts](/docs/language/c-cpp-calling/#templates-and-concepts) and [Generics](/docs/language/c-cpp-exposing/#generics) |
| `requires` clauses | ✅ | ? | A C++ `requires` clause, `enable_if`, `decltype` return or `void_t` test that fails removes the candidate, as in C++. Whether a Kairo [`requires`](/docs/language/requires/) clause reaches C++ is not documented |
| Virtual interfaces | — | ❌ | **Kairo-only.** Not compiled yet. Dispatch through a base class with `virtual` methods instead. See [Virtual Interfaces](/docs/language/interfaces/#virtual-interfaces) |
| **Classes** | | | |
| Classes | ◐ | ✅ | Imported C++ classes are constructed and called directly. Not yet: inherited constructors (`using Base::Base;`). Kairo classes keep their layout and vtables; copy and move constructors and the destructor (`op delete`) are public in C++ so C++ containers can hold the type. See [Classes](/docs/language/classes/) |
| Inheritance (`derives`) | ✅ | ✅ | A Kairo class can derive a C++ class, and a C++ class a Kairo one, abstract classes included. Every base is a public C++ base; a `priv` or `prot` base narrows its members through using-declarations. See [Inheritance](/docs/language/classes-inheritance/) |
| Multiple inheritance | ? | ✅ | A Kairo class with several bases has the platform's C++ layout. Deriving a Kairo class from several C++ classes is not documented. See [Multiple inheritance](/docs/language/classes-inheritance/#multiple-inheritance) |
| Virtual methods and abstract classes | ✅ | ✅ | Vtable-compatible both ways. A C++ override of a Kairo `virtual fn` must be `noexcept` unless the Kairo method is `@unwind`; a Kairo override of a `noexcept` C++ virtual must not be `@unwind`. See [Virtual Dispatch](/docs/language/classes-inheritance/#virtual-dispatch) |
| Access control (`pub`, `prot`, `priv`) | ? | ✅ | `priv` is `private:`, `prot` is `protected:`; the class befriends its file's functions. Struct fields are public in C++. A `priv` top-level declaration does not cross unless a `pub` inline or generic body names it. How Kairo treats C++ access is not documented. See [What crosses an include](/docs/language/c-cpp-exposing/#what-crosses-an-include) |
| `extend` | — | ✅ | **Kairo-only.** An extension member is not a C++ member function: it is a static function of a companion struct beside the type, taking the receiver as its first parameter, and a same-file `extend`'s companion is a friend of the type, so `priv` access works. An extension operator is also a free C++ operator. See [Using Kairo in C++](/docs/language/c-cpp-exposing/#what-a-kairo-declaration-looks-like-in-c) |
| RTTI and `dynamic_cast` | ? | ✅ | Kairo's checked downcast `p as *D?` compiles to `dynamic_cast`, and Kairo classes carry the platform's RTTI. A Kairo downcast of an imported C++ class is not documented. See [Casting](/docs/language/casting/) |
| **Operators** | | | |
| Operator overloading | ✅ | ✅ | C++ member operators, free operators found by ADL, hidden friends and operator templates all apply; unary `*` calls `operator*`. A Kairo `op` is a C++ operator. See [Operators on C++ types](/docs/language/c-cpp-calling/#operators-on-c-types) |
| Three-way comparison (`<=>`) | ✅ | ✅ | On a C++ operand, `<` and the other relational operators fall back to `<=>` as in C++20, and `!=` to `!(a == b)`. Kairo's `op <=>` returns `Ordering`. See [Derived comparisons](/docs/language/operator-overloading/#derived-comparisons) |
| `for` over a range | ✅ | ? | An imported C++ class iterates through `begin()` / `end()`, members or found by ADL ([for](/docs/language/control-flow/#for-range-and-iterator)). Whether C++'s range `for` can use a Kairo `op in` is not documented |
| **Errors** | | | |
| Panics (`panic`, `try` / `catch`) | — | ✅ | **Kairo-only.** C++ gets the `[[nodiscard]]` result union and reads it with `::builtin::ok`, `value`, `is<E>`, `error<E>`, `site`, or converts it to an exception with `value_or_throw`. The error's source location is found on ELF targets only so far. A C++ type can be panicked as a value. See [The value API](/docs/language/c-cpp-exceptions/#the-value-api) |
| C++ exceptions | ◐ | ❌ | **C++-only.** Caught by `catch e: cxx::std::exception` in either `try` form, provided every Kairo frame in between is `@unwind`; a `noexcept` Kairo frame terminates the program. Not yet: `e.what()` on an arm whose class redeclares it, and printing `what()` in an f-string. Kairo never throws by design: C++ code may convert a result with `value_or_throw`. See [Exceptions](/docs/language/c-cpp-exceptions/#exceptions) |
| `@unwind`, `@no_unwind`, `-funwind` | — | ✅ | **Kairo-only.** Every Kairo function is `noexcept` in C++; `@unwind` (or `-funwind`) removes it so a C++ exception can pass through. Not yet on a closure. See [C++ exceptions through Kairo frames](/docs/language/c-cpp-exceptions/#c-exceptions-through-kairo-frames) |
| **Memory** | | | |
| Heap allocation (`@create`, `@destroy`) | — | ✅ | **Kairo-only.** `@create T(args)` and `@destroy p` compile, with no import needed; the initializer form `@create T{...}` is not compiled yet ([Status](/docs/status/#not-compiled-yet)). Its pointer is a plain `T*` to C++: free it through Kairo (`destroy`), never with `free()` or `delete` ([What is still an error](/docs/language/c-cpp-memory/#what-is-still-an-error)). See [Heap Allocation](/docs/language/pointers/#heap-allocation) |
| C++ `new` / `delete` on Kairo classes | — | ❌ | Specified: every exported class carries the four class-specific `operator new` / `operator delete` functions, bound to Kairo's global allocator, so C++'s `new` / `delete` of a Kairo class goes through Kairo's allocator. Kairo code cannot define or overload them; a class defines only its constructors and destructor. Not yet: they are not emitted, so C++'s global operators are used ([Status](/docs/status/#not-compiled-yet)). See [Class-specific operator new and operator delete](/docs/language/c-cpp-memory/#class-specific-operator-new-and-operator-delete) |
| Global allocator (`@set_global_allocator`) | ✅ | ✅ | The global allocator is five C symbols: C or C++ can supply them, and C can call them. See [The global allocator ABI](/docs/language/allocators/#the-global-allocator-abi) |
| `CxxNewAllocator` | ? | — | Specified: routes Kairo's allocations through C++'s `operator new`. Its compile status is not documented. See [CxxNewAllocator](/docs/language/c-cpp-memory/#cxxnewallocator) |
| Scoped allocators | — | ? | **Kairo-only.** Specified to never reach a C++ `delete`, which relies on the class-specific operators above and on Tether, which is not in this release. See [Scoped allocator](/docs/language/allocators/#scoped-allocator) |
| Ownership and lifetime attributes in headers | — | ❌ | **Kairo-only.** Clang's `ownership_returns` / `ownership_takes`, `lifetimebound` and `gsl::Owner` / `gsl::Pointer` are derived from Tether and come with Stage 2 ([ABI stability](/docs/language/c-cpp-abi/#abi-stability-across-compiler-stages)). See [Ownership annotations](/docs/language/c-cpp-memory/#ownership-annotations-in-generated-headers) |
| Tether (lifetime analysis) | — | ❌ | **Kairo-only.** Not in this release. As designed, a raw pointer from C++ is untracked, a pointer handed to C++ loses its facts, and a function C++ can reach is treated as entered from an unknown thread. See [Tether: C/C++ Interop](/docs/language/tether-internals/#cc-interop) |
| **Concurrency** | | | |
| `thread` variables | ? | ✅ | A Kairo `thread` variable is a C++ `thread_local`. Using a C++ `thread_local` from Kairo is not documented. See [Thread-Local Variables](/docs/language/variables/#thread-local-variables) |
| Generators and coroutines | ? | ? | Kairo generators (`-> yield T`) compile to C++20 coroutines. Consuming a Kairo generator from C++, or a C++ coroutine type from Kairo, is not documented. See [Generators](/docs/language/functions-generators/) |
| `async`, `await`, `spawn`, `thread f()` | ❌ | ❌ | Not compiled yet: declarable as operators, but they do nothing. See [Concurrency](/docs/language/concurrency/) |

---

## A Note on C++ Modules

C++20 named modules (`import std;`, `import my_module;`) are **not currently supported**. The interop layer relies on header-based inclusion via Clang's preprocessor, and module interface deserialization (consuming pre-compiled BMIs) is a future roadmap item.

Exporting Kairo code as a C++ module interface unit (`.cppm`) is also planned but not yet implemented.

**For now:** use header-based interop ([`ffi "c++"`](/docs/language/c-cpp-calling/#the-ffi-keyword) + [`kcc`](/docs/language/c-cpp-toolchain/#kcc-the-c-driver)) for all cross-language boundaries.

## See also

- [Modules](/docs/language/modules/)
- [Imports](/docs/language/imports/)
- [Pointers](/docs/language/pointers/)
- [Unsafe](/docs/language/unsafe/)

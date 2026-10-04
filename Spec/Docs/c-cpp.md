# C & C++ Interoperability

Kairo provides zero-overhead, bidirectional interoperability with C and C++. There is no serialization layer, no
binding generator, and no runtime bridge — Kairo emits ABI-compatible object code and consumes C/C++ headers
directly.

The guarantee that makes this work is not a clever calling convention. It is that **Kairo ships its own pinned
Clang, and every translation unit on both sides of the boundary goes through it.** The failure mode that breaks
C++ interop for most languages — header parsed by compiler A, code compiled by compiler B, ABI mismatch
discovered at runtime — is designed out rather than mitigated.

This page covers the toolchain model, calling C/C++ from Kairo, exposing Kairo to C/C++, inline C++ and assembly,
pointer and reference passing, templates and concepts, allocators and ownership, the exception model, and the ABI
contract enforced at link time.

---

## Coverage Matrix

The table below summarizes which C and C++ features Kairo can consume and expose. Rows marked
**bidirectional** work in both directions.

| Feature | Direction | Notes |
|---|---|---|
| Functions | Bidirectional | Includes variadic functions |
| Structs | Bidirectional | Layout-compatible; see [Structs](/docs/language/structures) |
| Unions | Bidirectional | See [Unions](/docs/language/unions) |
| Enums | Bidirectional | See [Enums](/docs/language/enums) |
| Classes | Bidirectional | Vtable-compatible; see [Classes](/docs/language/classes) |
| Tuples | Bidirectional | Emitted as named structs; see [Tuples across the boundary](#tuples-across-the-boundary) |
| Templates | Bidirectional | Instantiation across the boundary; see [below](#templates-and-concepts) |
| Concepts | Bidirectional | Kairo's `impl` constraints map to C++20 concepts |
| Namespaces | Bidirectional | |
| Pointers & References | Bidirectional | Requires `unsafe` on the Kairo side; see [below](#pointers-and-references) |
| Operator Overloading | Bidirectional | See [Operators](/docs/language/operators) |
| Lambdas | Bidirectional | |
| Exceptions | C++ → Kairo only | Kairo never throws; its errors are values. See [Exceptions](#exceptions) |
| Macros | C++ → Kairo | Preprocessor macros are expanded before Kairo sees them |
| Preprocessor Directives | C++ → Kairo | |
| Inline Assembly | Kairo → C++ | Via `inline "asm"` blocks |
| Coroutines | Bidirectional | |
| Heap ownership | Bidirectional | Via class-specific `operator new`/`delete`; see [Allocators and Ownership](#allocators-and-ownership) |
| Named Modules (`import std;`) | Not yet | See [Modules note](#a-note-on-c-modules) |

---

## The Toolchain Model

Kairo ships two drivers. Both embed the **same pinned Clang**. Neither invokes a system compiler.

### `kairo` — the Kairo compiler

```sh
kairo foo.k              # produces foo.out
```

When `foo.k` contains `ffi "c++" import "header.h"`, `kairo` runs the pinned Clang's frontend over `header.h` to
extract declarations, then lowers `foo.k` to a Clang token stream and compiles it with **that same Clang
instance**. The compiler that read the header and the compiler that generated the code are byte-identical, so
there is no version skew to reconcile.

### `kcc` — the C++ driver

`kcc` is a drop-in replacement for `clang++`, with two additions:

- `#include "foo.k"` works. A Kairo file can be included directly into a C++ translation unit.
- Optionally, the Kairo standard library can be used in place of the C++ standard library, via a separate header.
  This is opt-in and off by default.

`kcc` is the supported way to compile C++ in a Kairo project. Using the system `clang++` or `g++` will usually
work, but forfeits the link-time ABI verification described [below](#link-time-abi-verification).

### Why a pinned Clang

The Clang version is identical across Kairo releases and identical across the language boundary. This is the
consistency guarantee the whole interop story rests on:

- The header you `ffi` in and the object you link against were processed by the same frontend.
- A Kairo type's layout and a C++ type's layout are computed by the same code.
- ABI-affecting behavior does not drift between the two sides of a call.

The trade-off is that Kairo does not use whatever compiler is installed on the machine. That is deliberate.

The same applies to the C++ standard library. A program that uses libc++ must link against the toolchain's own
libc++, not a copy installed on the system.

### Cross-compilation

Both `kairo` and `kcc` are full native cross-compilers. Targets are selected by triple, and system libraries come
from **curated sysroots** hosted for download rather than from the host machine:

```sh
kcc --target=x86_64-pc-windows-msvc foo.cc
kairo --target=aarch64-unknown-linux-gnu foo.k
```

Sysroots are pinned to specific library versions (a particular glibc, a particular Windows SDK), so a build is
reproducible across machines. Custom sysroots can be curated and registered locally.

> [!NOTE]
> Cross-compiling to a GCC or MSVC target does not mean invoking GCC or MSVC. `kairo` and `kcc` produce object
> code for those platforms' ABIs directly, using the pinned Clang and the curated sysroot.

---

## Calling C/C++ from Kairo

Import a C or C++ header with the `ffi` directive. The compiler parses the header, extracts declarations, and
makes them available as native Kairo symbols — no wrapper code required.

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
> `ffi "c++"` invokes the pinned Clang's frontend internally to parse the header. All exported declarations —
> functions, classes, enums, templates — become available in Kairo's scope with their original names and
> signatures. No code generation or binding step is visible to the user.

An imported function's default arguments are applied by C++, which can only leave out trailing arguments.
Naming a later parameter while an earlier defaulted one is omitted is an error (SC107E); pass the earlier
ones explicitly. See [Functions](/docs/language/functions#defaults-on-imported-c-functions).

---

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

### How `kcc` works

`kcc` is the pinned Clang driver with a preprocessor hook that intercepts `#include` directives. When the
included file has a `.k` extension, `kcc`:

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
kcc main.cpp my_code.o -o main
```

Using a third-party compiler at this step will work, but see
[Link-time ABI verification](#link-time-abi-verification) for what you give up.

> [!TIP]
> `kcc` is the simplest path for mixed codebases. The manual workflow is better when Kairo is a dependency
> consumed by an existing CMake/Meson/Bazel project that manages its own link step.

---

## Using Kairo from C++

### Headers

Every non-entry module can emit a C++ header. `--emit-headers <dir>` writes one per module at a path mirroring the module path: `geo::vec` becomes `<dir>/geo/vec.hh`. A C++ file includes it the way Kairo would import it:

```cpp
#include "geo/vec.hh"      // Kairo: import geo::vec
```

A header contains the module's `pub` declarations in their canonical namespaces, declarations only: class layouts, function signatures, enum definitions. Function bodies are in the module's object file; you compile the module with Kairo and link the result. A header `#include`s the headers of modules its layouts depend on and forward-declares everything else, so including one module does not drag in the tree.

A module that defines nothing (only comments, or only `pub import` re-exports) produces no object file and no
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

Extension methods are not C++ member functions. Kairo keeps a class's C++ definition identical everywhere it appears, so a method added by `extend` — even in the same file — is a free function taking the receiver as its first parameter. Call it as `geo::vec::len(&v)`.

Member type aliases are visible to C++: a class's `type promise_type = ...` is the C++ member
`promise_type`, so C++ code that looks a member type up by name finds it.

### Generics

Kairo generics are C++ templates in the header, bodies included. Instances Kairo already compiled are listed as `extern template`, so linking against the module's objects reuses them; any other instance is instantiated by your C++ compiler like any template. Kairo's `impl` bounds are not translated to C++ constraints: instantiating a Kairo generic with a C++ type that does not satisfy the bound fails inside the template body rather than at the call.

---

## Compiler Flags Across the Boundary

Kairo's flags and Clang's flags are not the same set. Some flags exist on one side only. `kcc` and `kairo`
perform **bidirectional translation**, not passthrough: a flag given to one driver is translated to its
equivalent on the other side when a translation unit is mixed.

Flags fall into three categories.

### 1. Translatable

The flag has an equivalent on both sides. It is translated and applied to both. This is the common case and
requires nothing from the user.

### 2. Single-language

The flag exists on one side only. This is legal **as long as the translation unit stays in one language**. The
moment the TU becomes mixed — a `.cc` that includes a `.k`, or a `.k` that `ffi`-imports a header — the flag is
an error:

```sh
kcc foo.cc --fno-float-prec          # fine: foo.cc is pure C++
```

```
error: '--fno-float-prec' has no Kairo equivalent and cannot be used in a mixed translation unit
  note: foo.cc:12 includes "bar.k", which makes this translation unit mixed
  note: remove the flag, or move the Kairo dependency into a separate translation unit
```

The diagnostic always names both the flag and the include that made the TU mixed. A flag that has worked for
years being rejected is only actionable if the reason is visible.

### 3. Layout-affecting

Some flags change how C++ lays out types or shapes vtables — `-fno-rtti`, `-fshort-enums`, struct-packing flags.
Kairo's ABI is fixed and cannot follow them. These are rejected in any translation unit that touches Kairo types,
and unlike category 2 there is no way to make them work:

```
error: '-fno-rtti' changes C++ type layout and cannot be used in a translation unit containing Kairo types
  note: Kairo's ABI is fixed; this flag would move it out from under the Kairo side
```

The distinction matters because the fix differs. Category 2 means *drop the flag*. Category 3 means *this can
never work in a mixed TU*.

---

## Link-time ABI Verification

Flag translation only sees a single invocation. Objects compiled at different times, by different people, with
different flags, and linked later are outside its reach. **`kld`** closes that gap.

Every object produced by `kairo` or `kcc` carries an ABI note section recording:

- the set of ABI-affecting settings that were in effect, canonicalized and sorted
- a hash of that set, for fast comparison
- a format version

At link time, `kld` compares hashes. A mismatch is a clean link error naming the specific flag:

```
error: ABI mismatch between input objects
  a.o was compiled with -fno-rtti
  b.o was compiled with -frtti
  note: these settings change type layout and cannot be mixed in one binary
```

The raw setting list is kept alongside the hash precisely so this message is possible — a hash alone can only say
*that* something mismatched, not *what*.

> [!NOTE]
> The hash covers the semantic set of resolved settings, not the command-line string. Flag order and alternate
> spellings of the same setting produce the same hash.

### Objects not built with the Kairo toolchain

`kld` links ordinary C++ objects, including prebuilt system libraries. Those have no ABI note, so nothing can be
verified about them. `kld` reports what it could not check:

```
warning: 3 object(s) were not built with kcc or kairo; ABI compatibility unchecked
  libfoo.a(bar.o), libfoo.a(baz.o), /usr/lib/qux.o
```

If one of those objects was built with mismatched settings, the result is a runtime crash with no diagnostic.
That is unavoidable — the information was never recorded — but the boundary of the guarantee is made visible
rather than left implicit. Suppress with `-Wno-unverified-abi`.

**This is the reason to use `kcc` rather than the system `clang++`.** Every object that goes through the Kairo
toolchain is covered.

---

## The `ffi` Keyword

`ffi` controls linkage and name mangling. It can be applied to individual declarations or to blocks.

```kairo
// C++ linkage — name mangling, overloading, classes, templates all permitted
ffi "c++" {
    fn compute(x: i32) -> i32 {
        return x + 1;
    }
}

// C linkage — no name mangling, same restrictions as extern "C" in C++
ffi "c" fn add(x: i32, y: i32) -> i32 {
    return x + y;
}
```

`ffi "c"` follows the same rules as `extern "C"` in C++: no classes, no overloading, no templates.
`ffi "c++"` follows the same rules as `extern "C++"`: full C++ feature set, Itanium or MSVC mangling depending
on the target.

### Name mangling

Kairo does not implement Itanium or MSVC mangling itself. Kairo constructs the corresponding Clang declaration
and asks Clang's `MangleContext` for the symbol. Both ABIs come from the same source of truth as the C++ side of
the boundary, and there is no second implementation to drift.

---

## Namespace Mapping

`std` means different things on the two sides of the boundary. The mapping is fixed:

| Spelling | On the Kairo side | On the C++ side |
|---|---|---|
| `std::` | Kairo's standard library | C++'s standard library |
| `cxx::std::` | C++'s standard library | — |
| `kairo::` | — | Kairo's own namespace, including its standard library |

From Kairo, the C++ standard library is always reached through `cxx::std::`:

```kairo
ffi "c++" import <vector>;

fn example() {
    var v: cxx::std::vector<i32>
    v.push_back(42)
}
```

Kairo's standard library lands inside `namespace kairo`, which is why a C++ translation unit sees Kairo's library
under `kairo::` and its own under the unqualified `std::` it already uses. Nothing is renamed on the C++ side.
Your own code lands in its module's namespace, or, for an entry file, in a namespace named after the file's stem.
See [Modules](/docs/language/modules#module-paths-are-c-namespaces).

> [!NOTE]
> `inline "c++"` blocks are not supported from Stage 1 onward. Use `ffi "c++"` to import declarations and call
> them as ordinary Kairo symbols. The older `__inline_cpp("...")` form is likewise removed.

---

## Inline ASM

For cases where you need to embed hardware-specific instructions, use `inline "asm"` blocks. Kairo uses the
extended assembly syntax (outputs, inputs, and clobbers) to allow safe interaction between assembly and Kairo
variables.

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

- **Volatile**: Use `inline "asm" volatile` if the assembly has side effects that the optimizer might otherwise
  remove (like a syscall or hardware port I/O).
- **Clobbers**: Always list registers modified by the assembly (like `memory` or specific registers) to prevent
  the Tether analysis and LLVM from making incorrect assumptions about the state of the machine.
- **Unsafe**: Assembly code is inherently unsafe and should be wrapped in an `unsafe` block to indicate that the
  programmer is responsible for ensuring the correctness of the assembly.

---

## Pointers and References

Kairo's [pointer model](/docs/language/pointers) distinguishes safe pointers (`*T`, non-nullable, tracked) from raw
pointers (`unsafe *T`, no tracking). Passing any pointer or reference across the FFI boundary requires explicit
`unsafe` context because the compiler cannot enforce safety guarantees on the C/C++ side.

C++ reference *parameters* (`T&`, `const T&`, `T&&`) are not pointers. They map to Kairo's parameter modes
(`@inout x: T`, `x: T`, `@move x: T`). See [Parameter passing modes](/docs/language/functions#parameter-passing-modes).

### Calls that return a reference

A call that returns a C++ reference, such as `v.at(i)`, `*p`, or `cout << x`, is usable directly as an operand
and as the target of an assignment:

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

See [Reference returns from C++](/docs/language/functions#reference-returns-from-c) for how these calls are typed.

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
    // shorthand syntax is not allowed — `unsafe add_one(unsafe &x)` is a compile error

    std::println(f"x = {x}")  // x = 42
}
```

`unsafe &` creates a raw pointer from a safe binding. The compiler relinquishes tracking for that pointer — the
caller is responsible for lifetime and aliasing correctness.

### Raw pointer from the start

If the value will be passed to C/C++ repeatedly, allocate it as a raw pointer upfront:

```kairo
ffi "c++" import "my_code.hh";

fn main() {
    var x: unsafe *i32 = @create i32(41)
    add_one(x)  // already unsafe — no block needed
    std::println(f"x = {*x}")  // x = 42
}
```

> [!WARNING]
> `unsafe *T` pointers can be null. Dereferencing a null `unsafe *T` is undefined behavior — the compiler will
> not insert a null check.

### Strings and `const char*`

A Kairo `string` cannot yet be passed to a C `const char*` parameter. The underlying pointer is `*u8`, and
`*u8` to `*i8` is neither an implicit nor a safe cast. A `string.c_str()` method is planned. Until it lands,
use `cxx::std::string` on the Kairo side, or add a small C++ helper that takes a `std::string` and makes the
C call.

---

## Allocators and Ownership

Heap ownership crosses the boundary in both directions, using the mechanism C++ already has for exactly this
purpose.

### Class-specific `operator new` and `operator delete`

Every exported Kairo class carries its own allocation operators, bound to Kairo's global allocator:

```cpp
class MyKairoClass {
public:
    static void *operator new(size_t);
    static void  operator delete(void *);
    static void *operator new[](size_t);
    static void  operator delete[](void *);
    ~MyKairoClass();
};
```

So from C++, the ordinary spelling is the correct one:

```cpp
MyKairoClass *p = new MyKairoClass("hi");
delete p;   // runs Kairo's destructor, then returns memory to Kairo's global allocator
```

This works because Kairo emits the class, and therefore emits the destructor. `~MyKairoClass` performs Kairo's
destruction semantics; C++'s `delete` merely sequences destructor-then-deallocate, which is the same pair of
operations Kairo spells as [`delete obj`](/docs/language/tether#delete-operation) followed by `@free`.

Pointer parameters and return values stay raw `*T` — there is no wrapper type, no ABI change, and no cost at the
call boundary.

### Global `operator new` overrides do not affect Kairo objects

A class-specific `operator new` takes precedence over a global replacement. A C++ translation unit that overrides
global `new`/`delete` — for a pool, an instrumented heap, a leak tracker — therefore does not touch Kairo
allocations. The isolation is structural, not a restriction.

### The operators bind to the *global* allocator, always

Kairo's [scoped allocator](/docs/language/tether#scoped-allocator) mechanism works by swapping the allocator the
process is currently using. The emitted `operator new` and `operator delete` deliberately **bypass** that
indirection and address the global allocator directly.

This matters. Consider a C++ `delete` that happens while a Kairo scoped allocator is active:

```kairo
@mem::set_scoped_allocator(ArenaAllocator)
fn work() {
    call_into_cxx()      // C++ runs `delete p` on a globally-allocated Kairo object
}
```

If `operator delete` followed the ambient allocator, that object would be handed to the arena's deallocator
instead of the global one. Binding to the global allocator unconditionally makes the pairing correct regardless
of what is active at the call site.

The invariant that makes this sound: **objects reachable from C++ were allocated by the global allocator.** A
pointer allocated through a scoped allocator that escapes the allocator's scope is a hard error under
[Tether](/docs/language/tether), so a scoped-allocated object cannot reach a C++ `delete` in the first place.

### What is still an error

The operators fix `new`/`delete`. They do not make every deallocation valid:

- `free()` on a pointer from `@create` — wrong deallocator, no destructor.
- `delete` on a pointer from `@alloc` — `@alloc` returns untyped storage with no constructed object.
- `delete` on an object allocated by a C++ `operator new` override in a TU that predates the Kairo declaration.

These are what the [ownership annotations](#ownership-annotations-in-generated-headers) below are for.

### `CxxNewAllocator`

For code that wants Kairo's *own* allocations to follow C++'s allocation path — so that a global `operator new`
override does apply to them — `core` provides `CxxNewAllocator`:

```kairo
@mem::set_allocator(core::CxxNewAllocator)
```

This is the unusual case, not the default. The [intentional friction](/docs/language/tether#global-allocator) rule
applies: the annotation must appear at the top of every file in the affected dependency graph.

### Ownership annotations in generated headers

Declarations emitted for the C++ side carry Clang's ownership attributes, tagged with the Kairo allocator
identity:

```cpp
void *kairo_alloc(size_t) __attribute__((ownership_returns(kairo_global)));
void  kairo_free(void *)  __attribute__((ownership_takes(kairo_global, 1)));
```

Clang's static analyzer (`MallocChecker`) uses these to flag mismatched allocation and deallocation across the
boundary. Because `kcc` controls the compiler invocation, this checking is available as a driver flag rather than
requiring a separate `scan-build` step.

> [!NOTE]
> The allocator identity string is part of the interop contract and is pinned in the ABI specification. Both
> sides must agree on it.

Kairo's own semantic analysis enforces the same rule independently and produces a Kairo-quality diagnostic. The
Clang attributes exist so that C++ consumers benefit too.

### Lifetime annotations

Emitted declarations carry `[[clang::lifetimebound]]` and the `[[gsl::Owner]]` / `[[gsl::Pointer]]` pair where
the Kairo side can prove the relationship. Unlike the ownership attributes, these are diagnosed during ordinary
compilation via `-Wdangling`, so a lifetime relationship proven on the Kairo side becomes a real compile-time
warning on the C++ side.

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

`T impl Addable` in Kairo maps directly to `Addable T` in the generated C++ — the constraint is preserved across
the boundary, not erased.

---

## Tuples Across the Boundary

Kairo tuples — `(i32, f32)` — are emitted as ordinary named structs in a reserved namespace, one per distinct
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

## Exceptions

Kairo and C++ signal failure differently, and the two models meet at one place: a Kairo `try`/`catch`.

- **Kairo never throws.** A Kairo failure is a [panic](/docs/language/panic): a tagged union value returned to
  the caller. No exception ever starts in Kairo code.
- **C++ throws.** A C++ exception is unwound by the platform unwinder (libunwind on Unix-like systems).
- **`try`/`catch` handles both.** Around a Kairo call it lowers to a `match` on the returned tagged union.
  Around a C++ call it catches C++ exceptions through the unwinder.

### C++ → Kairo

Kairo can catch C++ exceptions using its standard `try`/`catch` syntax.

```kairo
ffi "c++" import "my_code.hh";

fn main() {
    try {
        might_throw(true);
    } catch e: cxx::std::exception {
        std::println(f"Caught: {e.what()}")
    }
}
```

The exception does not have to be thrown directly inside the `try`. It can come from a C++ call several Kairo
frames down, and the unwinder passes through the Kairo frames in between to reach the `catch`. The compiler emits
unwind info for exactly those frames: a Kairo function gets it only when it sits between a C++ call and a Kairo
`try` that can catch from that call. Kairo code with no such path carries no unwind tables.

> [!NOTE]
> Unlike Kairo's [panic system](/docs/language/panic), the compiler cannot statically determine every exception
> type a C++ function might throw. A `catch` block that doesn't handle a thrown type lets the exception continue
> to the next enclosing Kairo `try`. An exception that no Kairo `try` catches keeps unwinding like any C++
> exception. If it reaches a [`@no_unwind`](/docs/language/attributes#unwinding) function, the program
> terminates (`std::terminate`).

### Kairo → C++: Kairo never throws

Kairo does not throw. `panic` is a checked effect with a typed, inferred set: a Kairo error is a tagged union
value returned to the caller, not an object propagated by the unwinder. No exception ever starts in Kairo code.

- A C++ caller never needs a `try`/`catch` to handle a Kairo error; it inspects the returned value.
- A C++ exception thrown by C++ code that Kairo calls can unwind through Kairo frames, unless a Kairo `try`
  catches it.
- A function marked [`@no_unwind`](/docs/language/attributes#unwinding) has `noexcept` on its generated C++
  declaration and definition, so `noexcept`-conditional C++ code that calls it takes the `noexcept(true)`
  branch. An exception that reaches it terminates the program.

#### The value API

A fallible Kairo function returns its result union directly. C++ sees a type carrying the tag and the possible
outcomes, and inspects it without any unwinding involved.

#### Converting to an exception

Because chaining over a tagged union is unidiomatic in C++, the result type also offers a conversion to a thrown
exception. The conversion is a method on the result type rather than a second entry point per function: one
generated symbol, no name collisions, and it composes with the rest of an expression.

The conversion is **generated C++**. It inspects the tag and throws from the C++ side of the boundary. Kairo
itself still never throws, and the real entry point is unaffected. C++ callers who
want exceptions get them; callers who want values keep the value API.

Throwing a Kairo error *out of Kairo* is not a roadmap item — it is excluded by the effect system. The conversion
is a translation at the boundary, not a change to how Kairo signals failure.

> [!NOTE]
> The exact spelling of the result type and its conversion method is not yet finalized.

---

## ABI Compatibility

Kairo emits object code conforming to the platform's native C++ ABI:

- **Unix-like systems:** Itanium C++ ABI
- **Windows:** Microsoft C++ ABI

Name mangling, vtable layout, RTTI, and struct layout all follow the platform convention, so Kairo `.o`/`.obj`
files link with object files from any ABI-compliant C++ compiler without shims or translation layers.

`ffi "c++"` declarations use C++ mangling. `ffi "c"` declarations use C mangling (no decoration). This matches
the behavior of `extern "C++"` and `extern "C"` in C++.

Two Kairo-specific guarantees strengthen the baseline:

- **Kairo never throws.** See [above](#kairo--c-kairo-never-throws).
- **ABI settings are recorded in the object and verified at link.** See
  [Link-time ABI verification](#link-time-abi-verification).

### Emission stages

Kairo lowers to a Clang token stream at every stage. Later stages emit *more* information, not different
information — the ABI does not change:

| Stage | Emits |
|---|---|
| Stage 1 | The core lowering: declarations, definitions, ordering, mangling. |
| Stage 2 | The same, plus lifetime, aliasing, and ownership attributes derived from Tether analysis. |

Objects from either stage are ABI-compatible. Stage 2's additions give the C++ side more static checking, not a
different layout.

---

## Declaration Ordering

C++ requires a type to be complete before it is used by value. Kairo does not impose that ordering on the
programmer — declarations may appear in any order in a `.k` file — so the emitter reconstructs a valid order.

Emission proceeds in four phases:

1. Forward declarations for every user type, in any order. This satisfies every pointer and reference edge.
2. Function and method declarations, in any order.
3. Type definitions, in dependency order over **by-value** edges only: value members, bases, fixed-array
   elements, and template arguments that land by value.
4. Function bodies, in source order.

A cycle in the phase-3 graph is a genuine error — a type whose definition requires its own layout has no finite
size — and is diagnosed on the Kairo side with the full cycle path:

```
error: recursive type definition requires infinite size
  `A` contains `B` by value
  `B` contains `A` by value
  note: use `*A` to break the cycle
```

Pointer and reference members do not create this edge, which is why `struct B { *A a; }` is legal alongside
`struct A { B b; }`.

---

## A Note on C++ Modules

C++20 named modules (`import std;`, `import my_module;`) are **not currently supported**. The interop layer
relies on header-based inclusion via Clang's preprocessor, and module interface deserialization (consuming
pre-compiled BMIs) is a future roadmap item.

Exporting Kairo code as a C++ module interface unit (`.cppm`) is also planned but not yet implemented.

**For now:** use header-based interop (`ffi "c++"` + `kcc`) for all cross-language boundaries.
# C & C++ Interoperability

Kairo provides zero-overhead, bidirectional interoperability with C and C++. There is no serialization layer, no binding generator, and no runtime bridge. Kairo emits ABI-compatible object code and consumes C/C++ headers directly.

The guarantee that makes this work is not a clever calling convention. It is that **Kairo ships its own pinned Clang, and every translation unit on both sides of the boundary goes through it.** The failure mode that breaks C++ interop for most languages (header parsed by compiler A, code compiled by compiler B, ABI mismatch discovered at runtime) is designed out rather than mitigated.

This page covers the toolchain model, calling C/C++ from Kairo, exposing Kairo to C/C++, inline C++ and assembly, pointer and reference passing, templates and concepts, allocators and ownership, the exception model, and the ABI contract enforced at link time.

## In this section

- [kairo, kcc & Cross-compilation](/docs/language/c-cpp-toolchain/)
- [Calling C and C++ from Kairo](/docs/language/c-cpp-calling/)
- [Using Kairo in C++](/docs/language/c-cpp-exposing/)
- [Allocators & Ownership](/docs/language/c-cpp-memory/)
- [Exceptions & Panics](/docs/language/c-cpp-exceptions/)
- [ABI Contract & Verification](/docs/language/c-cpp-abi/)

---

## Coverage Matrix

The table below summarizes which C and C++ features Kairo can consume and expose. Rows marked **bidirectional** work in both directions.

| Feature | Direction | Notes |
|---|---|---|
| Functions | Bidirectional | Includes variadic functions |
| Structs | Bidirectional | Layout-compatible; see [Structs](/docs/language/structures/) |
| Unions | Bidirectional | See [Unions](/docs/language/unions/) |
| Enums | Bidirectional | See [Enums](/docs/language/enums/) |
| Classes | Bidirectional | Vtable-compatible; see [Classes](/docs/language/classes/) |
| Tuples | Bidirectional | Emitted as named structs; see [Tuples across the boundary](/docs/language/c-cpp-exposing/#tuples-across-the-boundary) |
| Templates | Bidirectional | Instantiation across the boundary; see [below](/docs/language/c-cpp-calling/#templates-and-concepts) |
| Concepts | Bidirectional | Kairo's `impl` constraints map to C++20 concepts |
| Namespaces | Bidirectional | |
| Pointers & References | Bidirectional | Requires `unsafe` on the Kairo side; see [below](/docs/language/c-cpp-calling/#pointers-and-references) |
| Operator Overloading | Bidirectional | See [Operators on C++ types](/docs/language/c-cpp-calling/#operators-on-c-types) and [Operators](/docs/language/operators/) |
| Lambdas | Bidirectional | |
| Exceptions | C++ to Kairo only | Kairo never throws; its errors are values. See [Exceptions](/docs/language/c-cpp-exceptions/#exceptions) |
| Macros | C++ to Kairo | Preprocessor macros are expanded before Kairo sees them |
| Preprocessor Directives | C++ to Kairo | |
| Inline Assembly | Kairo to C++ | Via `inline "asm"` blocks |
| Coroutines | Bidirectional | |
| Heap ownership | Bidirectional | Via class-specific `operator new`/`delete`; see [Allocators and Ownership](/docs/language/c-cpp-memory/#allocators-and-ownership) |
| Named Modules (`import std;`) | Not yet | See [Modules note](#a-note-on-c-modules) |

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

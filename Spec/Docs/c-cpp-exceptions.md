# Exceptions & Panics

## Exceptions

Kairo and C++ signal failure differently, and the two models meet at one place: a Kairo `try`/`catch`.

- **Kairo never throws.** A Kairo failure is a [panic](/docs/language/panic/): a tagged union value returned to the caller. No exception ever starts in Kairo code.
- **C++ throws.** A C++ exception is unwound by the platform unwinder (libunwind on Unix-like systems).
- **`try`/`catch` handles both.** Around a Kairo call it lowers to a [`match`](/docs/language/pattern-matching/) on the returned tagged union. Around a C++ call it catches C++ exceptions through the unwinder.

### C++ to Kairo

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

The exception does not have to be thrown directly inside the `try`. It can come from a C++ call several Kairo frames down, and the unwinder passes through the Kairo frames in between to reach the `catch`. The compiler emits unwind info for exactly those frames: a Kairo function gets it only when it sits between a C++ call and a Kairo `try` that can catch from that call. Kairo code with no such path carries no unwind tables.

> [!NOTE]
> Unlike Kairo's [panic system](/docs/language/panic/), the compiler cannot statically determine every exception type a C++ function might throw. A `catch` block that doesn't handle a thrown type lets the exception continue to the next enclosing Kairo `try`. An exception that no Kairo `try` catches keeps unwinding like any C++ exception. If it reaches a [`@no_unwind`](/docs/language/attributes/#unwinding) function, the program terminates (`std::terminate`).

### Kairo to C++: Kairo never throws

Kairo does not throw. [`panic`](/docs/language/panic/#the-panic-specifier) is a checked effect with a typed, inferred set: a Kairo error is a tagged union value returned to the caller, not an object propagated by the unwinder. No exception ever starts in Kairo code.

- A C++ caller never needs a `try`/`catch` to handle a Kairo error; it inspects the returned value.
- A C++ exception thrown by C++ code that Kairo calls can unwind through Kairo frames, unless a Kairo `try` catches it.
- A function marked [`@no_unwind`](/docs/language/attributes/#unwinding) has `noexcept` on its generated C++ declaration and definition, so `noexcept`-conditional C++ code that calls it takes the `noexcept(true)` branch. An exception that reaches it terminates the program.

#### The value API

A fallible Kairo function returns its result union directly. C++ sees a type carrying the tag and the possible outcomes, and inspects it without any unwinding involved.

#### Converting to an exception

Because chaining over a tagged union is unidiomatic in C++, the result type also offers a conversion to a thrown exception. The conversion is a method on the result type rather than a second entry point per function: one generated symbol, no name collisions, and it composes with the rest of an expression.

The conversion is **generated C++**. It inspects the tag and throws from the C++ side of the boundary. Kairo itself still never throws, and the real entry point is unaffected. C++ callers who want exceptions get them; callers who want values keep the value API.

Throwing a Kairo error *out of Kairo* is not a roadmap item; it is excluded by the effect system. The conversion is a translation at the boundary, not a change to how Kairo signals failure.

> [!NOTE]
> The exact spelling of the result type and its conversion method is not yet finalized.

## See also

- [C & C++ Interoperability](/docs/language/c-cpp/)
- [kairo, kcc & Cross-compilation](/docs/language/c-cpp-toolchain/)
- [Calling C and C++ from Kairo](/docs/language/c-cpp-calling/)
- [Using Kairo in C++](/docs/language/c-cpp-exposing/)
- [Allocators & Ownership](/docs/language/c-cpp-memory/)
- [ABI Contract & Verification](/docs/language/c-cpp-abi/)
- [Panic](/docs/language/panic/)
- [Attributes](/docs/language/attributes/)

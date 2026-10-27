# Exceptions & Panics

## Exceptions

Kairo and C++ signal failure differently, and the two models meet at one place: a Kairo `try`/`catch`.

- **Kairo never throws.** A Kairo failure is a [panic](/docs/language/panic/): a tagged union value returned to the caller. No exception ever starts in Kairo code.
- **C++ throws.** A C++ exception is unwound by the platform unwinder (libunwind on Unix-like systems).
- **Kairo frames are `noexcept`.** Every Kairo function, method, constructor, operator and closure is `noexcept` in its generated C++, unless it is marked [`@unwind`](/docs/language/attributes/#unwinding) or the program is built with `-funwind`. A C++ exception that reaches a `noexcept` Kairo frame terminates the program (`std::terminate`).
- **`try`/`catch` handles both.** Around a Kairo call it lowers to a tag compare per `catch` arm on the returned tagged union. Around a C++ call it catches C++ exceptions through the unwinder.

### C++ to Kairo

Kairo can catch C++ exceptions using its standard `try`/`catch` syntax.

```kairo
ffi "c++" import "my_code.hh";   // void might_throw(bool); void log_message(const char*)

fn main() {
    try {
        might_throw(true);
    } catch e: cxx::std::exception {
        log_message(e.what())         // e is the C++ exception object
    }
}
```

> [!NOTE]
> Two limits on reading the message from Kairo for now. Printing `e.what()` in an f-string fails in the C++ step: C++'s `const char*` is not yet usable as a Kairo `*const i8` ([Status](/docs/status/#not-compiled-yet)); pass it on to C or C++ code instead, as above. And on an arm whose class redeclares `what()` (`cxx::std::runtime_error`), the call is reported as ambiguous (SC064E); read the message through a `cxx::std::exception` arm.

A `catch e: T` arm whose `T` is a C++ type that the `try` body cannot [panic](/docs/language/panic/) with catches a C++ exception of type `T`, by C++'s own rules: an exception of a class derived from `T` matches too, and the arms are tried in order. `e` refers to the exception object. Such an arm is never checked against the panic set and never reported as dead. A C++ type that *is* in the body's panic set is an ordinary panic arm.

Which C++ calls are covered is decided by where they are written: a C++ call inside the `try` body, however deeply nested in its expressions and blocks, is covered. The function holding the `try` stays `noexcept`; the `try` is a real C++ `try` inside it. An exception that no arm matches reaches the function's `noexcept` boundary and terminates the program, as one thrown anywhere else in a `noexcept` frame does. A bare `catch` catches panics only, never a C++ exception.

```kairo
fn read_or_default(x: i32) -> i32 {
    try {
        return checked_double(x)
    } catch e: cxx::std::runtime_error {
        return 0                          // a std::logic_error here would terminate
    }
}
```

The expression form works the same way: `try checked_double(x) catch e: cxx::std::exception => -1`. C++ arms and panic arms can share one `try`.

`panic e` inside a C++ arm panics a copy of the caught exception (of the arm's type) as a Kairo error, raised at that `panic`.

C++ exception arms need C++ exceptions: in a build with `-fno-exceptions`, or for a target with no OS where they default off, such an arm is an error ([SC001E](/docs/language/diagnostics/)), with a fix-it removing it.

The exception can come from a C++ call several Kairo frames down, but every Kairo frame between the `throw` and the `catch` must let it through: mark each one [`@unwind`](/docs/language/attributes/#unwinding), or build with `-funwind`. A frame that is `noexcept` (the default) stops the exception by terminating the program, before the `catch` is reached. The frame holding the `try` itself does not need `@unwind`: the exception stops there.

```kairo
@unwind fn relay(x: i32) -> i32 {
    return checked_double(x) + 1        // C++, may throw: passes through relay
}

fn guarded(x: i32) -> i32 {
    try { return relay(x) } catch e: cxx::std::exception { return -1 }
}
```

> [!NOTE]
> Unlike Kairo's [panic system](/docs/language/panic/), the compiler cannot statically determine every exception type a C++ function might throw. A `catch` block that doesn't handle a thrown type lets the exception continue to the next enclosing frame, which terminates the program if it is `noexcept`.

### C++ exceptions through Kairo frames

A C++ function that throws and catches internally works under any Kairo caller: nothing reaches the Kairo frame. What `noexcept` decides is an exception that leaves the C++ code Kairo called:

| The Kairo frame it reaches | What happens |
|---|---|
| A plain Kairo function (the default) | `std::terminate`: the program aborts |
| An `@unwind` function, or any function under `-funwind` | The exception passes through, to the next frame up (a C++ `catch` in a C++ caller works) |
| A `@no_unwind` function | `std::terminate`, even under `-funwind` |

```kairo
ffi "c++" import "guard.hh"      // int checked(int) throws; int guard(int (*)(int), int) catches

@unwind fn relay(x: i32) -> i32 { return checked(x) + 1 }

fn main() -> i32 {
    return guard(relay, -4)       // -1: thrown through relay, caught by guard in C++
}
```

Without `@unwind` on `relay`, the same program aborts with the C++ runtime's "terminating due to uncaught exception" message.

The flags:

- `-fno-unwind` (the default): every Kairo function is `noexcept`, except those marked `@unwind`.
- `-funwind`: no Kairo function is `noexcept`, except those marked `@no_unwind`. Closures follow the flag (a closure cannot be marked `@unwind` yet). Build every Kairo module and `kcc` host of one program with the same setting.
- C++ exceptions themselves are on for a hosted target. A freestanding target (no OS in the target triple, `--freestanding`, kernel mode) has no unwinder and keeps them off unless `-fexceptions` asks; `-fno-exceptions` turns them off anywhere.

`noexcept` is part of the C++ contract a Kairo declaration exposes. A C++ class that overrides a Kairo `virtual fn` must mark its override `noexcept` too (C++ rejects an override whose exception specification is laxer than the base's), unless the Kairo method is `@unwind`. The other way, a Kairo override of a C++ `virtual` that is `noexcept` must not be `@unwind`. A function declared with `ffi` linkage, or imported from a C/C++ header, keeps the exception specification its C/C++ declaration states.

### Kairo to C++: Kairo never throws

Kairo does not throw. [`panic`](/docs/language/panic/#the-panic-specifier) is a checked effect with a typed set, inferred or declared: a Kairo error is a tagged union value returned to the caller, not an object propagated by the unwinder. No exception ever starts in Kairo code.

- A C++ caller never needs a `try`/`catch` to handle a Kairo error; it inspects the returned value.
- A C++ exception thrown by C++ code that Kairo calls terminates the program when it reaches a Kairo frame, unless that frame is [`@unwind`](/docs/language/attributes/#unwinding) (or the program is built with `-funwind`), in which case it unwinds through.
- Every Kairo function that is not `@unwind` has `noexcept` on its generated C++ declaration and definition, so `noexcept`-conditional C++ code that calls it (`std::vector` reallocation, `std::move_if_noexcept`) takes the `noexcept(true)` branch.

#### The value API

A fallible Kairo function returns its result union directly, by value and `[[nodiscard]]`. C++ sees a type carrying the tag, the source location of an error, and the possible outcomes, and inspects it without any unwinding involved.

The API over the result is a set of free function templates in the `::builtin` namespace (the same namespace that holds `::builtin::null`), emitted with the generated C++. They are free functions rather than members because the result type's class text must be identical in every translation unit and header.

| Helper | Meaning |
|---|---|
| `::builtin::ok(p)` | `true` when `p` holds a value |
| `::builtin::value(p)` | The value, by reference; only valid when `ok(p)` |
| `::builtin::is<E>(p)` | `true` when `p` holds an error of type `E` |
| `::builtin::error<E>(p)` | The error, as `E&`; only valid when `is<E>(p)` |
| `::builtin::site(p)` | A `::builtin::source_site { file, line, col }`: where the error was raised. `file` is null for a result that holds a value |
| `::builtin::type_id<E>` | The id of error type `E`, the value stored in the tag |
| `::builtin::panic_set<P>` | A trait over a result type `P`: `value_type` (`T`), `types` (`::builtin::panic_types<E...>`), `size` (the number of error types) and `payload_offset` (where the value and every error start) |

```cpp
#include "config.k"                    // pub fn load_port(path: string) panic(IOError, RangeError) -> i32

int port_or_default() {
    auto r = config::load_port("port.txt");
    if (::builtin::ok(r))
        return ::builtin::value(r);
    if (::builtin::is<config::RangeError>(r))
        return 0;                      // ::builtin::error<config::RangeError>(r) is the Kairo error value
    return 8080;                       // IOError
}
```

A panic set holds exact types (there is no subtyping between error types; see [Panic](/docs/language/panic/#arms-match-exact-types)), so `is<E>` matches only `E` itself. `is<E>` of a type not in the set is `false`; `error<E>` of one does not compile.

The function is declared `[[nodiscard]]`: dropping the result drops the error with it. A header written with `--emit-headers` declares the same function, includes the headers of its error types, and declares the result type `extern template`, so the C++ that includes several Kairo headers instantiates it once.

#### Converting to an exception

Because chaining over a tagged union is unidiomatic in C++, a result can be converted to a thrown exception with `::builtin::value_or_throw(p)`: it returns the value on success, and otherwise throws `::builtin::panic_error<E>` for the error type `E` the result holds.

```cpp
try {
    int port = ::builtin::value_or_throw(load_port("port.txt"));
    serve(port);
} catch (const ::builtin::panic_error<IOError>& e) {
    log(e.error.path);                 // the Kairo error value
} catch (const ::builtin::panic_error_base& e) {
    log(e.what());                     // any other Kairo error
}
```

- `::builtin::panic_error<E>` derives from `::builtin::panic_error_base`, which derives from `std::exception`, so `catch (const ::builtin::panic_error_base&)` catches any Kairo error and `catch (const std::exception&)` catches it too. Its `error` member holds the Kairo error value.
- `what()` is the error's [`op panic`](/docs/language/operator-overloading/#op-panic) message (the type's own, or one an `extend` gives it) followed by its type and source location: `<message> [<ErrorType> at <file>:<line>:<col>]`, for example `missing config key 'port' [ConfigError at app.k:12:9]`. A type with no `op panic` (it is optional) gives just the type and location: `ConfigError at app.k:12:9`. The file is the source file's path as the compiler records it, its full path (`/home/me/app/app.k`). The string is built once, when the exception is constructed, and its copies share it.
- The location is found only on ELF targets (Linux, the BSDs) so far; elsewhere `site(p)` has a null `file` and `what()` gives the type without a location. A C++ host linked against a Kairo `--shared` library sees only its own sites: an error raised inside the library has no location.
- `value_or_throw` takes the result by value: a temporary result's value or error is moved out, a named one's is copied. An error type that can only be moved works too; catch its `panic_error<E>` by reference.
- `panic_error_base`, `panic_error<E>` and `value_or_throw` exist only where the C++ is compiled with exceptions; the value API is always there.

The conversion is **generated C++**. It inspects the tag and throws from the C++ side of the boundary. Kairo itself still never throws, and the real entry point is unaffected. C++ callers who want exceptions get them; callers who want values keep the value API.

Throwing a Kairo error *out of Kairo* is not a roadmap item; it is excluded by the effect system. The conversion is a translation at the boundary, not a change to how Kairo signals failure.

## See also

- [C & C++ Interoperability](/docs/language/c-cpp/)
- [kairo, kcc & Cross-compilation](/docs/language/c-cpp-toolchain/)
- [Calling C and C++ from Kairo](/docs/language/c-cpp-calling/)
- [Using Kairo in C++](/docs/language/c-cpp-exposing/)
- [Allocators & Ownership](/docs/language/c-cpp-memory/)
- [ABI Contract & Verification](/docs/language/c-cpp-abi/)
- [Panic](/docs/language/panic/)
- [Attributes](/docs/language/attributes/)

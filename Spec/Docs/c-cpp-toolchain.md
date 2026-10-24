# kairo, kcc & Cross-compilation

## The Toolchain Model

Kairo ships two drivers. Both embed the **same pinned Clang**. Neither invokes a system compiler.

### `kairo`: the Kairo compiler

```sh
kairo foo.k              # produces foo.out
```

When `foo.k` contains [`ffi "c++" import "header.h"`](/docs/language/imports/#ffi-header-imports), `kairo` runs the pinned Clang's frontend over `header.h` to extract declarations. At the interop boundary, Kairo hands **that same Clang instance** a token stream containing exactly what it would emit if you requested a C++ header for `foo.k`. The compiler that read the header and the compiler that consumes Kairo's declarations are byte-identical, so there is no version skew to reconcile.

### `kcc`: the C++ driver

`kcc` is a drop-in replacement for `clang++`, with two additions:

- `#include "foo.k"` works. A Kairo file can be included directly into a C++ translation unit.
- Optionally, the Kairo standard library can be used in place of the C++ standard library, via a separate header. This is opt-in and off by default.

It takes Clang's command line: C, C++, Objective-C(++), `.k`, object and archive inputs, and Clang's options. An option Kairo has its own flag for becomes that flag; any other reaches the C and C++ compiles as given. A few things differ from `clang++`:

- **C++23 by default.** With no `-std=`, C++ is compiled as C++23. A lower `-std=` is accepted, down to C++20 for a translation unit that includes a `.k`: the emitted interface needs `constexpr`, `consteval`, `constinit` and `requires`.
- **The target and sysroot are Kairo's.** `kcc` is part of the toolchain, so the defaults come from it, not from the host compiler (see [Cross-compilation](#cross-compilation)).
- **`-Xkairo <word>`** passes one word to the Kairo side untranslated, for settings only `kairo` has (`-Xkairo --cxx-std=c++26`).
- `kcc --help` and `kcc --version` describe `kcc`, not Clang. `-###` prints each compile job and the link without running them.

`kcc` is the supported way to compile C++ in a Kairo project. Using the system `clang++` or `g++` will usually work, but forfeits the link-time ABI verification described [below](/docs/language/c-cpp-abi/#link-time-abi-verification).

### Why a pinned Clang

The Clang version is identical across Kairo releases and identical across the language boundary. This is the consistency guarantee the whole interop story rests on:

- The header you `ffi` in and the object you link against were processed by the same frontend.
- A Kairo type's layout and a C++ type's layout are computed by the same code.
- ABI-affecting behavior does not drift between the two sides of a call.

The trade-off is that Kairo does not use whatever compiler is installed on the machine. That is deliberate.

The same applies to the C++ standard library. A program that uses libc++ must link against the toolchain's own libc++, not a copy installed on the system.

### Cross-compilation

Both `kairo` and `kcc` are full native cross-compilers. Targets are selected by triple, and system libraries come from **curated sysroots** hosted for download rather than from the host machine:

```sh
kcc --target=x86_64-pc-windows-msvc foo.cc
kairo --target=aarch64-unknown-linux-gnu foo.k
```

Sysroots are pinned to specific library versions (a particular glibc, a particular Windows SDK), so a build is reproducible across machines. Custom sysroots can be curated and registered locally.

How `--target` finds its sysroot:

- A `--target` uses the sysroot bundled with the compiler: `<prefix>/sysroot/<dir>`, where `<prefix>` is the directory above the one holding `kairo`.
- The folder is matched by target, not by spelling. Vendor, OS version, and LLVM's aliases do not matter, but the sub-architecture does. So `x86_64-pc-windows-msvc` finds `x86_64-windows-msvc`, `x86_64-linux-gnu` finds `x86_64-linux-gnu-glibc2.31`, `aarch64-apple-darwin` finds `arm64-apple-macosx`, and `arm64e` does not match `arm64`.
- `-m32` / `-m64` look up the architecture they switch to: `--target=x86_64-linux-musl -m32` uses `i686-linux-musl`.
- A bundled sysroot takes precedence over `--sysroot`. With no matching folder, `--sysroot` is used if given; otherwise there are no system headers.
- A matching folder without a loadable `SYSROOT.toml` is an error: [P007E](/docs/language/diagnostics/#p007e-bundled-sysroot-for-the-target-is-malformed) "bundled sysroot for the target is malformed".

> [!NOTE]
> Cross-compiling to a GCC or MSVC target does not mean invoking GCC or MSVC. `kairo` and `kcc` produce object code for those platforms' ABIs directly, using the pinned Clang and the curated sysroot.

### How `kcc` works

`kcc` is the pinned Clang driver with a preprocessor hook that intercepts `#include` directives. When the included file has a `.k` extension:

1. **Before anything compiles,** `kcc` scans each C++ input, and the project headers it includes, for `#include "*.k"`, resolving each the way Clang will (the including file's directory, then `-iquote`, then `-I`). An `-I` directory is also a Kairo [search directory](/docs/language/modules/#search-directories-and-library-names), so a `.k` found through it has the same module path as when it is imported. Every `.k` found is part of the build whether or not the command line names it. The scan does not preprocess: a `.k` behind `#if 0` is still built, and an include spelled through a macro is not found (it is an error at the include).
2. **The Kairo compiler analyses the `.k` in the same process** and, at the include, hands Clang a token stream: the file's [`pub` interface](/docs/language/c-cpp-exposing/#what-crosses-an-include) in its [module namespace](/docs/language/modules/#module-paths-are-c-namespaces), plus every template and `inline` body the C++ code compiles itself. No header file is written, and the system and `ffi` headers the interface needs are included ahead of it. Diagnostics in the C++ code point into the `.k`.
3. **In a run that links,** the `.k` is compiled to an object and linked with the C++ objects. Under `-c` it is a header to that run, and gets no object of its own (see [Separate compilation](#separate-compilation)).

A `.k` included twice in one translation unit is included once, and two `.k` files that share a module (or the builtin library) share one copy of it. `-E` prints the stream as C++ that compiles on its own. A `.cc` and a `.k` with the same name write `foo.o` and `foo.k.o`.

### Separate compilation

`kcc` compiles one file at a time the way Clang does:

```sh
kcc -c x.cc        # x.cc includes y.k: y.k is analysed for the include, no y.o
kcc -c y.k         # writes y.o, and nothing for what y.k imports
kcc x.o y.o -o main
```

`-c` writes objects only for the files the command line names. What they import is compiled by its own `kcc -c`, as a C++ source would be. The final link needs Kairo's builtin library, the standard library and the runtime, which no `-c` run wrote: `kcc` links them from the toolchain's library, built on first use for the target and code-generation options and cached under `$KAIRO_CACHE_DIR` (default `$XDG_CACHE_HOME/kairo`, then `~/.cache/kairo`). It is rebuilt when the compiler or a library source changes, and a library no link has used for 30 days is removed. It is linked like an archive, so only what the objects use is pulled in.

A template instance used on both sides is instantiated by each, and the linker keeps one: the include carries no `extern template`, because the C++ object and the Kairo object may come from different runs.

### Manual workflow (without `kcc`)

If you prefer a standard C++ build process, compile the Kairo source to a static library and a generated header, then link normally:

```sh
kairo my_code.k -c -o my_code -xc++ -header my_code.hh
kcc main.cpp my_code.o -o main
```

Using a third-party compiler at this step will work, but see [Link-time ABI verification](/docs/language/c-cpp-abi/#link-time-abi-verification) for what you give up.

> [!TIP]
> `kcc` is the simplest path for mixed codebases. The manual workflow is better when Kairo is a dependency consumed by an existing CMake/Meson/Bazel project that manages its own link step.

---

## Compiler Flags Across the Boundary

Kairo's flags and Clang's flags are not the same set. Some flags exist on one side only. `kcc` and `kairo` perform **bidirectional translation**, not passthrough: a flag given to one driver is translated to its equivalent on the other side when a translation unit is mixed.

Flags fall into three categories.

### 1. Translatable

The flag has an equivalent on both sides. It is translated and applied to both. This is the common case and requires nothing from the user.

### 2. Single-language

The flag exists on one side only. This is legal **as long as the translation unit stays in one language**. The moment the TU becomes mixed (a `.cc` that includes a `.k`, or a `.k` that `ffi`-imports a header), the flag is an error:

```sh
kcc foo.cc --fno-float-prec          # fine: foo.cc is pure C++
```

```
error: '--fno-float-prec' has no Kairo equivalent and cannot be used in a mixed translation unit
  note: foo.cc:12 includes "bar.k", which makes this translation unit mixed
  note: remove the flag, or move the Kairo dependency into a separate translation unit
```

The diagnostic always names both the flag and the include that made the TU mixed. A flag that has worked for years being rejected is only actionable if the reason is visible.

### 3. Layout-affecting

Some flags change how C++ lays out types or shapes vtables: `-fno-rtti`, `-fshort-enums`, struct-packing flags. Kairo's ABI is fixed and cannot follow them. These are rejected in any translation unit that touches Kairo types, and unlike category 2 there is no way to make them work:

```
error: '-fno-rtti' changes C++ type layout and cannot be used in a translation unit containing Kairo types
  note: Kairo's ABI is fixed; this flag would move it out from under the Kairo side
```

The distinction matters because the fix differs. Category 2 means *drop the flag*. Category 3 means *this can never work in a mixed TU*.

## See also

- [C & C++ Interoperability](/docs/language/c-cpp/)
- [Calling C and C++ from Kairo](/docs/language/c-cpp-calling/)
- [Using Kairo in C++](/docs/language/c-cpp-exposing/)
- [Allocators & Ownership](/docs/language/c-cpp-memory/)
- [Exceptions & Panics](/docs/language/c-cpp-exceptions/)
- [ABI Contract & Verification](/docs/language/c-cpp-abi/)
- [Diagnostics](/docs/language/diagnostics/)
- [Modules](/docs/language/modules/)

# kairo, kcc & Cross-compilation

## The Toolchain Model

Kairo ships two drivers, `kairo` and `kcc`, written in Kairo (the compiler compiles itself). Both embed the **same pinned Clang** (an LLVM 22 fork). Neither invokes a system compiler.

A release archive holds `bin/` (`kairo`, `kcc`, `kld`, `kfmt`, `llvm-symbolizer`, `llvm-ar`, `llvm-ranlib`, `llvm-lib`) and `lib/` (including `lib/clang/22`). There are no `clang` or `clang++` binaries: `kairo` and `kcc` run clang in-process and `kld` runs lld in-process. The `lib/` tree holds Clang's resource directory with compiler-rt, and the builtin, std and runtime sources). Archives exist for static musl Linux (x86_64, i686, aarch64, armv7, riscv64), Windows (MinGW; x86_64, i686, aarch64, armv7), FreeBSD (x86_64, aarch64), NetBSD (x86_64) and macOS (x86_64 10.15+, arm64 11+). Only x86_64 Linux is run by the test suite. The sysroots for every cross target are one separate archive, unpacked as `<prefix>/sysroot`.

### `kairo`: the Kairo compiler

```sh
kairo foo.k              # links ./a.out
kairo foo.k -o foo       # names the output
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

Both `kairo` and `kcc` are full native cross-compilers. Targets are selected by triple, and system libraries come from **sysroots** that `--target` generates on demand (and caches) rather than from the host machine. Two are never shipped or generated: Apple's SDK and Microsoft's MSVC / Windows SDK. On macOS the installed SDK is used (`xcrun --show-sdk-path`), on Windows the installed MSVC / Windows SDK, and cross-compiling to either from another host needs an SDK you supply with `--sysroot`. A `--target` build is hermetic; a build without one also searches the host's system directories, after the sysroot (see [Host headers and libraries](#host-headers-and-libraries)):

```sh
kcc --target=x86_64-pc-windows-msvc foo.cc
kairo --target=aarch64-unknown-linux-gnu foo.k
```

Sysroots are pinned to specific library versions (a particular glibc, a particular Windows SDK), so a build is reproducible across machines. A sysroot of your own can be given with `--sysroot=<dir>` (without `--target`); its `SYSROOT.toml` describes the layout.

How `--target` finds its sysroot:

- A `--target` uses the sysroot generated for it, kept beside the compiler: `<prefix>/sysroot/<dir>`, where `<prefix>` is the directory above the one holding `kairo`.
- The folder is matched by target, not by spelling. Vendor, OS version, and LLVM's aliases do not matter, but the sub-architecture does. So `x86_64-pc-windows-msvc` finds `x86_64-windows-msvc`, `x86_64-linux-gnu` finds `x86_64-linux-gnu-glibc2.31`, `aarch64-apple-darwin` finds `arm64-apple-macosx`, and `arm64e` does not match `arm64`.
- `-m32` / `-m64` look up the architecture they switch to: `--target=x86_64-linux-musl -m32` uses `i686-linux-musl`.
- A bundled sysroot takes precedence over `--sysroot`. With no matching folder, `--sysroot` is used if given; otherwise the compiler warns ([P008W](/docs/language/diagnostics/)) and there are no system headers.
- A matching folder without a loadable `SYSROOT.toml` is an error: [P007E](/docs/language/diagnostics/#p007e-bundled-sysroot-for-the-target-is-malformed) "bundled sysroot for the target is malformed".

### Host headers and libraries

A build sees the machine it runs on in one of three ways, decided by the flags:

| Mode | Flags | C library | Host headers and libraries |
|---|---|---|---|
| Default | no `--target`, no `--sysroot` | The bundled sysroot for this host (glibc 2.31 on a glibc Linux host, musl on a musl host) | Searched **after** the sysroot |
| Native | `--native` | The host's own | Searched as clang does natively |
| Hermetic | `--target=<triple>` (or `--sysroot`) | The bundled sysroot for the triple | Never |

**Default.** On a glibc Linux host a plain `kairo main.k` builds for `<arch>-unknown-linux-gnu` against the bundled glibc 2.31 sysroot, the *glibc floor*. The program then runs on any Linux with glibc 2.31 or newer. On top of the floor, the host's system directories are searched last:

- Headers: the bundled libc++, then Clang's builtin headers, then the floor's glibc headers, and only then the host's `/usr/local/include`, `/usr/include/<multiarch>` and `/usr/include` (as `-idirafter`). `<stdio.h>` always comes from the floor. Only a header the floor lacks, such as `zlib.h` or `curl/curl.h`, comes from the host.
- Libraries: the sysroot's library directory, then the host's `/usr/local/lib`, `/usr/lib/<multiarch>`, `/usr/lib64`, `/usr/lib`, `/lib/<multiarch>`, `/lib64` and `/lib`. `libc` and `libm` always come from the floor.

So installed C libraries work without extra flags beyond naming them:

```kairo
ffi "c" import "curl/curl.h"

fn main() -> i32 {
    var unsafe *v = curl_version()
    return 0
}
```

```sh
kairo main.k --pkg-config libcurl -o main
```

`kairo --print-clang-args main.k` shows the header search order, and `kairo --print-dirs main.k` the library search order (the host's directories are listed under `host library search`).

**What raises the floor.** A host library was built against the host's glibc, which is usually newer than 2.31. Linking one can make the program need that newer glibc:

- A host **shared** library is linked with `--allow-shlib-undefined`, because the floor's `libc.so` lacks the newer symbol versions it uses. After the link, Kairo reads the library's version needs and warns when one is above the floor:
  `warning [L001W]: 'libcurl.so.4' needs GLIBC_2.43, so this program needs glibc 2.43 or newer to run (the floor is 2.31)`.
  The program runs on this machine. To run it on an older one, ship it with that library (or one built against an older glibc).
- A host **static** archive (`.a`) from a host directory gets a warning too: once it is linked in, nothing can see what it needs from glibc, so it can raise the floor silently.

The floor is Linux-only. On macOS and Windows the default build uses the bundled SDK or MinGW-w64 sysroot as before.

**Native: `--native`.** Builds against the host's own C library, headers and libraries, in Clang's normal native search order, like Zig's native mode. There is no sysroot. The bundled libc++, libunwind and compiler-rt are still used (linked by path, so the host's `libc` is the one linked). The program needs the host's glibc version, with no floor. `--native` cannot be combined with `--target`: one names this machine, the other a triple built hermetically. `--native` is implemented for Linux hosts so far.

**Hermetic: `--target`.** A `--target` build uses the bundled sysroot only. No host directory and no host environment search path is ever consulted, so a cross build gives the same result on every machine. Naming a root with `--sysroot`, or building `--freestanding`, is hermetic too.

#### `--pkg-config`

`--pkg-config <name>` (repeatable) runs `pkg-config --cflags --libs <name>` and applies the result:

- `-I`, `-isystem`, `-D` and `-U` go to Clang, for `ffi` headers and C/C++ inputs.
- `-L`, `-l`, `-pthread` and `-Wl,...` go to the link.
- A `-I` or `-L` naming a host system directory is dropped, because those are already searched after the sysroot. As a `-I` it would come before the sysroot, and `-I/usr/include` ahead of libc++ breaks `<cstring>`.

pkg-config reads `PKG_CONFIG_PATH`, `PKG_CONFIG_LIBDIR` and `PKG_CONFIG_SYSROOT_DIR` itself, and `PKG_CONFIG` names a different program. A missing pkg-config, or a package it does not know, is an error naming the package. With `--target`, `--pkg-config` is an error unless `PKG_CONFIG_SYSROOT_DIR` or `PKG_CONFIG_LIBDIR` is set, because the host's `.pc` files describe the host, not the target.

#### Environment variables

In the default and native modes, Kairo honors the variables Clang's driver reads, in the same positions:

| Variable | Effect |
|---|---|
| `CPATH` | Like `-I`, after the command line's own `-I` |
| `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH` | System include directories for C and C++, searched after the sysroot's headers |
| `LIBRARY_PATH` | Library directories, after the sysroot's and before the host's defaults |
| `NIX_CFLAGS_COMPILE`, `NIX_LDFLAGS` | Their `-isystem` / `-idirafter`, `-L` and `-rpath` words, as on Nix |

A `--target` build ignores all of them.

#### C++ libraries from the host

Kairo links its own libc++. A host C++ library built against GCC's libstdc++ is not ABI-compatible with it wherever `std::` types cross the boundary (`std::string`, containers, exceptions). Host C libraries are fine. For a C++ library, build it with the toolchain (`kcc`) or use its C API.

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

`-c` writes objects only for the files the command line names. What they import is compiled by its own `kcc -c`, as a C++ source would be. The final link needs Kairo's builtin library, the standard library and the runtime, which no `-c` run wrote: `kcc` links them from the toolchain's library, built on first use for the target and code-generation options and cached under `$KAIRO_CACHE_DIR` (default `$XDG_CACHE_HOME/kairo`, then `~/.cache/kairo`, then `%LOCALAPPDATA%\kairo`). It is rebuilt when the compiler or a library source changes, and a library no link has used for 30 days is removed. It is linked like an archive, so only what the objects use is pulled in.

Every link, with `kcc` or `kairo`, also caches the runtime's C objects (the allocator and the runtime support code) in the same directory, under `rt/`. An object is reused only when its exact compile line (target, optimization level, sanitizers and every other flag that reaches it) and every runtime source it is built from, the compiler itself included, are unchanged; anything else rebuilds it. `--force-recompile` rebuilds them for one run, and `-v` reports a hit or miss for each.

A template instance used on both sides is instantiated by each, and the linker keeps one: the include carries no `extern template`, because the C++ object and the Kairo object may come from different runs.

### Incremental compilation

With `--cache-dir <dir>` (`-Xkairo --cache-dir=<dir>` through `kcc`), `kairo` reuses the object of every Kairo file whose compiled form has not changed since an earlier run against the same directory. Without it nothing is cached and every run is a full build.

```sh
kairo main.k -o main --cache-dir build/cache   # first run: every file compiled
kairo main.k -o main --cache-dir build/cache   # no change: every object reused
```

The unit is one file. Every run still parses and type-checks the whole program; a reused file skips code generation and the C++ compile behind it, which is most of a build. A file's object is keyed by what its compile would be given, worked out after type checking:

- Editing the body of an ordinary function recompiles only its own file.
- Changing something an importer compiles against recompiles the file and the importers that use it: a signature, a default argument, a generic or `inline` body, a class's layout (private fields included), or a fact the compiler inferred from a body, such as a function's purity. A declaration no importer uses recompiles nobody else.
- Editing a C or C++ header the program imports recompiles every Kairo file of the program.
- Anything that changes objects recompiles everything: another compiler build, another target, or an option that reaches code generation (`-O`, `-g`, `-D`, `-f` flags, sanitizers). `-A`, a Kairo-only `-W`, `--error-format` and link options (`-l`, `-L`, `--rpath`, `--static`) recompile nothing. For now a `-W` that reaches Clang (`-Wall`, say) recompiles everything too, because a reused object must report the same C++ warnings and those are not stored yet.

A reused file still reports its warnings: type checking runs every time, and the compiler's own code-generation warnings are produced again. A file Clang warns about is never stored, so it is compiled, and warns, on every run.

Each object carries its cache key in a section the linker drops (`.kairo.cache` on ELF, `__KAIRO,__cache` on Mach-O, `.kcache` on COFF), so the linked program is byte-identical to a clean build's. Without `-g` the key holds no path of the machine, so a cache directory can be copied to another checkout or machine and is used wherever the keys match. An object whose record is missing, damaged or names another key is never used: the file is compiled again and the entry replaced. Builds with different options or targets keep their objects side by side under `<dir>/kairo-cache-v<N>/`.

On a terminal, a build shows one status line, such as `[codegen 41/338, 297 reused] Sema/Type/CallTyping.k  0:09`, that disappears before any diagnostic prints. `--progress=never` turns it off; `--progress=lines` prints one `@progress phase=sema done=212 total=338 file=...` line per finished file instead, for a script to read. The default, `auto`, shows the line whenever stderr is a terminal (unless `TERM` is `dumb`), and never when output is piped or redirected.

`--print-stats` prints each run's counts (`[stats] incremental: 41 reused, 2 compiled, 2 stored`), `-v` names each file that compiled and the part of its key that changed, and `--force-recompile` compiles every file for one run.

### Driver flags

| Flag | Meaning |
|---|---|
| `--progress=auto\|always\|never\|lines` | the status line described above; `auto` (default) only on a terminal |
| `--sema-threads=N` | threads that type-check import groups in parallel; 0 (default) follows `--threads`, 1 runs one at a time |
| `--codegen-threads=N` | threads of the per-file C++ compiles; 0 (default) follows `--threads`, never more than the file count |
| `--interface-pch=auto\|on\|off` | share one precompiled copy of the Kairo interfaces between files; `auto` (default) builds it only for larger programs |
| `--cache-dir <dir>`, `--force-recompile` | [incremental compilation](#incremental-compilation) |
| `-Wconst-self` | opt-in lint: a method that never mutates `self` should be declared `const self` (with a fix-it) |
| `--help-hidden` | also list internal and not-yet-implemented flags |

Pretty diagnostics print the location as `file:line:col`.

### Manual workflow (without `kcc`)

If you prefer a standard C++ build process, compile the Kairo source to an object and write its C++ headers, then link normally. `--emit-headers <dir>` writes one header per module (`gen/my_code.hh`, plus the builtin ones it includes); the C++ file includes `my_code.hh` instead of the `.k`. `--emit-scope=inputs` writes an object for `my_code.k` only, as `clang -c` does, not for every Kairo file the run reaches:

```sh
kairo my_code.k -c --emit-scope=inputs -o my_code.o --emit-headers gen
kcc -Igen main.cpp my_code.o -o main
```

The final link needs Kairo's builtin library and runtime, which `kcc` supplies. Using a third-party compiler for the link means linking those yourself, and gives up the checks described in [Link-time ABI verification](/docs/language/c-cpp-abi/#link-time-abi-verification).

> [!TIP]
> `kcc` is the simplest path for mixed codebases. The manual workflow is better when Kairo is a dependency consumed by an existing CMake/Meson/Bazel project that manages its own link step.

---

## Compiler Flags Across the Boundary

Kairo's flags and Clang's flags are not the same set. `kcc` translates a Clang option into the Kairo flag when Kairo has one (`-O2`, `-g`, `-fno-exceptions`, `-fstack-protector-strong`, `--target`), and any other option reaches the C and C++ compiles as given, never the link. `-Xkairo <word>` and `--cxx-flags=<flag>` say which side a word is for.

```sh
kcc main.cpp -fstack-protector-strong     # -> --stack-protector=strong, for both sides
kcc main.cpp -fno-strict-aliasing         # no Kairo flag: C++ compile only
kairo main.k --cxx-flags=-Wshadow         # Clang flag for the C/C++ inputs and ffi headers only
```

> [!NOTE]
> Not yet: a flag that exists on one side only is not rejected in a mixed translation unit, and neither are layout-affecting flags (`-fshort-enums`, struct packing). They are accepted and applied to the C/C++ side alone, so the two sides can silently disagree on a layout. Rejecting them with a diagnostic naming the flag and the include that made the unit mixed is planned. Until then, do not pass a layout-changing flag to a unit that touches Kairo types. `-fno-rtti` is a Kairo flag too (`-f[no-]rtti`), and `kcc` translates it.

An unknown option is an error (`error: unknown argument: '--fno-float-prec'`), as in Clang.

### Exceptions

C++ exceptions are on in a Kairo translation unit's C++ on a hosted target, and off on a freestanding one (no OS in the triple, `--freestanding`, kernel mode) unless `-fexceptions` is given; `-fno-exceptions` turns them off. Separately, `-funwind` / `-fno-unwind` (the default) decide whether Kairo functions are `noexcept`: see [Exceptions & Panics](/docs/language/c-cpp-exceptions/#c-exceptions-through-kairo-frames). Use one `-funwind` setting for every Kairo module and `kcc` host in a program.

### Hardening, symbol and code-model flags

These use Clang's names. A toggle is `-f<name>` / `-fno-<name>`, and a setting with a value is `--<name>=<value>`. Each one applies to Kairo code and to the C/C++ compiled with it, and `kcc` translates the Clang spelling for you.

| Kairo | Clang | Values |
|---|---|---|
| `--stack-protector=` | `-fstack-protector`, `-fstack-protector-strong`, `-fstack-protector-all` | `none`, `basic`, `strong`, `all` |
| `-f[no-]stack-protector` | the same | shorthand for `basic` / `none`; `--stack-protector=` wins |
| `--cf-protection=` | `-fcf-protection=` | `none`, `branch`, `return`, `full` (x86 CET) |
| `--zero-call-used-regs=` | `-fzero-call-used-regs=` | `skip`, `used-gpr-arg`, `used-gpr`, `used-arg`, `used`, `all-gpr-arg`, `all-gpr`, `all-arg`, `all` |
| `--trivial-auto-var-init=` | `-ftrivial-auto-var-init=` | `uninitialized`, `zero`, `pattern` |
| `-f[no-]delete-null-pointer-checks` | the same | on by default |
| `--tls-model=` | `-ftls-model=` | `global-dynamic`, `local-dynamic`, `initial-exec`, `local-exec` |
| `--visibility=` | `-fvisibility=` | `default`, `hidden`, `protected` |
| `-f[no-]visibility-inlines-hidden` | the same | off by default |
| `-f[no-]plt` | the same | on by default |
| `-f[no-]red-zone` | `-m[no-]red-zone` | on where the ABI has one |
| `--mcmodel=` | `-mcmodel=` | `tiny`, `small`, `kernel`, `medium`, `large` |

Without `--tls-model`, each `thread` global gets a TLS model of its own. Builtin and std globals are `initial-exec`. Your globals are `local-exec` when they link into an executable, and general-dynamic in a `--shared` library or a `-c` object. `--tls-model` sets the model for your globals; builtin and std globals stay `initial-exec`.

### No passthrough with `--`

`kairo` has no raw Clang passthrough. After a bare `--`, every word is an input file, so `kairo main.k -- -ftls-model=initial-exec` is an error that names the Kairo spelling. To pass a Clang flag to the C and C++ inputs alone, use `--cxx-flags=<flag>` (repeatable). Kairo's own code never sees those flags.

## See also

- [C & C++ Interoperability](/docs/language/c-cpp/)
- [Calling C and C++ from Kairo](/docs/language/c-cpp-calling/)
- [Using Kairo in C++](/docs/language/c-cpp-exposing/)
- [Allocators & Ownership](/docs/language/c-cpp-memory/)
- [Exceptions & Panics](/docs/language/c-cpp-exceptions/)
- [ABI Contract & Verification](/docs/language/c-cpp-abi/)
- [Diagnostics](/docs/language/diagnostics/)
- [Modules](/docs/language/modules/)

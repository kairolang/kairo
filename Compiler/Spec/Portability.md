# Portability

How the compiler chooses and describes a target, which external standards it follows, and the platform rules its own source obeys. Toolchain discovery is in [Driver.md](Driver.md#toolchain-discovery), sysroots for linking in [Linking.md](Linking.md#sysroots), and building and staging the compiler for each host in [BuildSystem.md](BuildSystem.md). What a type or an FFI signature means on a target is language semantics: the language reference's `primitives`, `conversion-lattice` and `c-cpp-abi` pages ([primitives](README.md#language-reference), [conversion-lattice](README.md#language-reference), [c-cpp-abi](README.md#language-reference)) own it, and this document only describes how the compiler gets the facts those pages rely on.

All compiler work is cross-platform by default: Linux (glibc and musl), macOS, Windows (MinGW and MSVC environments) and the BSDs, unless a change is explicitly scoped to one platform. Build and tooling scripts are Python (`build.py`, `Scripts/stage_tree.py`, `Scripts/cross_llvm.py`) and handle each platform's binary format and loader rules (ELF RUNPATH, Mach-O `@loader_path`, DLLs beside the executable).

## Targets

### Effective triple

Every target-dependent decision reads one triple, the effective triple, computed once in `CompilerInstance::_apply_invocation` (`Compiler/Driver/CompilerInstance.k`):

1. `--target` if given, else the default triple below.
2. `-m32` / `-m64` rewrite the architecture to its 32- or 64-bit variant (`x86_64` to `i386`).
3. The result is normalized (`llvm::Triple::normalize`) and stored as `TargetOptions::effective_triple` (`Compiler/Config/Target.k`). Diagnostics name this triple, never the raw `--target` spelling.

`--host` is accepted and ignored (marked unimplemented in `Compiler/Command/FlagRegistry.k`, U005W).

### Default triple

`CompilerInstance::get_default_target_triple` takes the host's architecture and OS and substitutes a C library the toolchain ships:

| Host | Default triple |
|---|---|
| Linux, glibc loader present | `<arch>-unknown-linux-gnu` (built against the bundled glibc 2.31 sysroot, so the program runs on any later glibc) |
| Linux, otherwise | `<arch>-unknown-linux-musl` |
| 32-bit ARM Linux | as above with the `eabi` / `eabihf` environment kept (`gnueabihf`, `musleabihf`, ...) |
| Windows | `<arch>-pc-windows-gnu`, never `msvc` |
| anything else | the host triple unchanged |

`HostSystem::host_libc` (`Linker/API/HostSystem.k`) decides glibc versus musl by the presence of the host's dynamic loader. `--native` uses the same triple and swaps the bundled sysroot for the host's libraries.

The Linux vendor is always `unknown`, never the host's (`pc` on many distributions). The bundled musl sysroots and their compiler-rt directories are named `<arch>-unknown-linux-musl`, clang's canonical spelling. With a host-derived `x86_64-pc-linux-musl`, any clang handed Kairo's target (the test suite's link driver, a user's build system) finds no `libclang_rt.builtins` directory, and every link fails with a missing builtins archive or an undefined `operator new`. Kairo's own linker hides the mismatch by trying vendor variants (`Toolchain::_rt_triples`, `Linker/API/Toolchain.k`), so the failure shows only in foreign links. The glibc default follows the same rule.

### Triple spelling sent to clang

`FlagTranslator::clang_triple` (`Compiler/Command/FlagTranslator.k`) rewrites the triple only in the words that reach clang (the `-cc1 -triple`, the driver probe, the driver line for C/C++ inputs). The build keeps the user's spelling, so sysroot lookup still uses it.

| Kairo triple | clang triple | Reason |
|---|---|---|
| `*-wasi` | `*-wasip1` | clang warns on the bare `wasi` OS on every run |
| `arm*-windows-*` (not `arm64`) | `thumb*-windows-*` | Windows on 32-bit ARM is Thumb-2 only; the clang driver makes this rewrite itself, but the `-cc1` line is Kairo's, and an `armv7` triple reached CodeView emission and failed with "target architecture doesn't map to a CodeView CPUType" |

### Derived target facts

The driver derives every target fact from the effective triple in one place, after `-m32`/`-m64`, and writes it into `TargetOptions`. No fact has its own flag: a fact that disagrees with the triple describes no real target. `Config/` and Sema never see LLVM or clang types; they read these fields. `resolved` is false for a hand-built invocation that skipped the driver, and consumers that must not guess (the `f80` gate) treat that as "unknown" rather than "not x86".

| Field | Source | Meaning |
|---|---|---|
| `arch_name`, `vendor_name`, `os_name`, `env_name`, `object_format` | `llvm::Triple` | components, for diagnostics and gating |
| `pointer_width` | `llvm::Triple` | 0 in a hand-built invocation, read as 64 |
| `is_little_endian`, `is_x86`, `has_os` | `llvm::Triple` | `has_os` is false for bare metal: no unwinder, so C++ exceptions default off |
| `int64_is_long` | `clang::TargetInfo::getInt64Type()` | `int64_t` is `long` rather than `long long` |
| `usize_is_fixed`, `isize_is_fixed` | `getSizeType()` / `getPtrDiffType()` against the type Kairo spells for `u<pw>` / `i<pw>` | `size_t` is the same C++ type as the fixed-width integer of pointer width |
| `long_double_is_x87`, `long_double_fmt_name`, `long_double_bits`, `long_double_align` | `getLongDoubleFormat()`, `getLongDoubleWidth()`, `getLongDoubleAlign()` | the `f80` gate and its layout |
| `has_float128` | `hasFloat128Type()` | whether a diagnostic may suggest `f128` |

`CompilerInstance::_fill_clang_type_facts` builds a throwaway `clang::TargetInfo` for the triple, copies the answers, and drops it. If clang does not know the triple, it falls back to ISA-level guesses so `f80` does not add a second error next to the P004F that rejects the triple.

Clang answers these questions because hand-written triple lists get them wrong. Darwin and OpenBSD are LP64 with a `long long` `int64_t`; 32-bit targets and Windows (LLP64) also spell it `long long`; only some LP64 targets use `long`. Pointer width alone does not decide `size_t` either: Linux LP64 spells `size_t` and `uint64_t` both `unsigned long`, Windows both `unsigned long long`, and Darwin uses `unsigned long` and `unsigned long long`, two distinct C++ types and so two distinct overloads.

### Integer mapping across the C++ boundary

Clang integer builtins map to Kairo integers by width and signedness, never by builtin kind (`TypeImport::_builtin`, `Compiler/Sema/Foreign/TypeImport.k`). Keying on `Long` / `LongLong` with LP64 widths imported Windows `uint64_t` (`unsigned long long`) as `u32` and broke every 64-bit integer crossing the FFI on LLP64.

In the export direction `i64`/`u64` are spelled as the target's `int64_t`: `CanonicalTypes::init` (`Compiler/AST/Context/CanonicalTypes.k`) chooses `long` or `long long` from `int64_is_long`, and `TypeExport::_int_of` and `TypeImport::is_int_alias` use the same answer. A C integer of the same width that is not the target's natural spelling (LLP64 `long` next to `int`, Darwin `unsigned long` next to `uint64_t`) is an alias: overload resolution prefers the natural parameter on a tie (`Compiler/Sema/Type/OverloadResolution.k`), and an argument passed by pointer or non-const reference to an alias parameter is cast to the parameter's own spelling at the call (`ParamDecl::cxx_alias_ptr`), because C++ converts no pointer between same-width integer types. A specialization whose integer argument is such an alias records no specialization hint, so a header's `allocator<unsigned long>` cannot claim Kairo's `allocator<u64>` on Darwin. The language rule (`size_t` reads as `usize`, a plain `unsigned long` stays a fixed-width integer) is in the language reference's conversion lattice.

Two C overloads that share one Kairo type at one rank (libc++'s `operator<<(double)` and `(long double)` where `long double` is binary64; `unsigned long` and `unsigned long long` on LP64 Darwin) are ambiguous for a Kairo argument. Not resolved.

### `f80` and `long double`

`f80` lowers to C++ `long double`, so it exists exactly where the target ABI's `long double` is x87 extended. That is an ABI fact: x86_64-windows-msvc has x87 hardware and a binary64 `long double`, x86_64 Android has binary128. The gate is `TypeResolve::_target_supports` (`Compiler/Sema/Resolve/TypeResolve.k`), which reads `long_double_is_x87` and reports P003E at the spelling of the type. `is_x86` only picks the wording ("x87 exists but this ABI's 'long double' is binary64" versus "requires x87"). The fix-it suggests the Kairo type that equals C's `long double` on the target (`f64` for binary64, `f128` for binary128), and suggests `f128` otherwise only when `has_float128` holds.

The compiler never substitutes a type for `f80`: `f128` is a different format whose every operation is a compiler-rt libcall, and `f64` drops 11 bits of significand without telling anyone. `PrimitiveLimitDesugar` (`Compiler/Sema/Expand/PrimitiveLimitDesugar.k`) applies the same gate to `f80` limits (`f80::MAX` and the like).

On import, clang's `long double` maps by size and then format: 64 bits to `f64`; 128 bits to `f80` if x87, `f128` if IEEE quad, and opaque for IBM double-double (`TypeImport::_builtin`).

The builtin library must compile on every target, so it carries no unconditional `f80` signature: `FmtBuf::put_f80` is commented out (`Lib/builtin/fmt/fmt_buf.k`) until it can be declared per target.

### Codegen targets

The vendored LLVM is built with 16 backends plus the experimental Xtensa: X86, AArch64, ARM, RISCV, WebAssembly, PowerPC, SystemZ, Mips, LoongArch, Sparc, AVR, MSP430, BPF, NVPTX, AMDGPU and SPIRV (`TARGETS` in `Scripts/build_llvm.py`, shared with `Scripts/cross_llvm.py`; [BuildSystem.md](BuildSystem.md#native-build)). A backend being present does not mean a sysroot exists for it: `ksys` builds one on first use for the targets its recipes cover ([SysRoot.md](SysRoot.md)). The release tree ships sysroots for Linux (glibc 2.31 and musl; x86_64, i686, aarch64, armv7, riscv64), Windows (MinGW and MSVC environments; x86_64, i686, aarch64, armv7), macOS (x86_64, arm64, arm64e), FreeBSD (x86_64, aarch64), NetBSD (x86_64) and `wasm32-wasi`; their layout and selection are in [Linking.md](Linking.md#sysroots). Target-resolution diagnostics:

| Code | When |
|---|---|
| P003E | a primitive type does not exist on the target (`f80`) |
| P004F | clang does not know the triple |
| P005F | the target machine cannot be constructed |
| P006E | `--mcpu` names a CPU the target does not have; on x86, so does `--march`, which names a CPU there (clang's `-march=haswell`). Elsewhere `--march` is an ISA string only clang's per-target parsers read, and `native` is left to the clang driver |
| P007E | a bundled sysroot is malformed |
| P008W | a root or sysroot is not found |

### Compiler hosts

The compiler itself builds for the hosts in `Scripts/cross_llvm.py`'s `FAMILIES` (Linux musl, Windows MinGW, FreeBSD, NetBSD, macOS) with conservative CPU floors (x86-64-v2, pentium4 for 32-bit x86, armv8-a, rv64gc, apple-m1). How those builds run is in [BuildSystem.md](BuildSystem.md#release-packaging).

## Standards compliance

Kairo emits C++ and hands it to an in-process clang, so most external standards (object formats, calling conventions, the Itanium and MSVC C++ ABIs, DWARF) are met by clang and LLVM for the target triple. Kairo defines no ABI of its own. The rules that bind Kairo declarations to the C/C++ ABI (layout, name mangling, cross-stage stability) are language rules in the language reference's `c-cpp-abi` page; exception propagation across the boundary is in [Panic.md](Panic.md#interop-with-c-exceptions).

### C++ dialect

Kairo TUs and C++ inputs compile as `--cxx-std`, default `c++23` (`TargetOptions::cxx_std`, `Compiler/Config/Target.k`; the driver copies it into the backend config in `CompilerInstance.k`). Accepted values are `c++20`, `c++23`, `c++26` and their `gnu++` spellings. C inputs use clang's own default C standard unless `--c-std` is given (default value `c17`).

### C++ ABI

The C++ ABI follows the triple: Itanium everywhere except `*-windows-msvc`, which uses the MSVC ABI. `--cxx-abi` is accepted and ignored (unimplemented, U005W).

### Floating point

Binary floating-point types other than `f80` are IEEE 754 formats (the language reference's `primitives` page owns their semantics, including that NaN propagates without trapping).

| Flag | Default | Effect |
|---|---|---|
| `--fp-model` | `precise` | `strict`: no contraction, `-frounding-math`, `-ffp-exception-behavior=strict`, full complex range. `fast`: the `-ffast-math` bundle with promoted complex range |
| `--fp-contract` | `off` | `off`, `on`, `fast`; given explicitly, it wins over `--fp-model` |
| `--fast-math` | off | the `-ffast-math` bundle with basic complex range |

`FlagTranslator::codegen` spells these as cc1 words (`Compiler/Command/FlagTranslator.k`); cc1 has no `-ffp-model`, so each model is spelled as the individual options the clang driver would expand it to.

Kairo code and C++ headers imported into the same clang TU keep different default FP semantics:

- `FlagTranslator::kairo_fp_cc1` pins `-ffp-contract=off` for Kairo's compile line, ahead of the user's own words so an explicit flag still wins. Contraction is the one cc1 default the clang driver changes for C++ (to `on`); the other precise-model defaults (no `-ffp-model`, no math `errno`) are cc1's own.
- `FlagTranslator::header_fp_pragmas` wraps each FFI header region in pragmas that restore what clang++ gives C++ on the target: the driver's contraction and math-`errno` defaults read from the target probe, or the user's FP flags where given. `#pragma float_control(precise, on)` comes first (it is the only pragma that restores `errno`, and it also sets contraction on), then the contraction pragma, inside a push/pop pair. Clang records the FP state per parsed body and instantiates templates under their pattern's state, so header code keeps C++ semantics wherever Kairo uses it, and the same expression written in Kairo keeps Kairo's.
- Where the target does not honour `float_control` (`TargetInfo::hasStrictFP` false; wasm), no `float_control` pragma is written, `errno` cannot be restored, and the closing line restores Kairo's contraction directly.

C and C++ input files never see these: they compile on the clang driver line with clang's defaults.

### Debug information

`-g` emits DWARF version `--dwarf-version` (2 to 5, default 5, `CodeGenOptions::dwarf_version` in `Compiler/Config/CodeGen.k`). On `*-windows-msvc` the version is left out (`FlagTranslator::dwarf_for` returns 0) and clang emits CodeView, which the MSVC-environment linkers need for PDBs. `--split-dwarf` is unimplemented (U005W).

### Reproducible output

| Flag | Effect |
|---|---|
| `--source-date-epoch=<n>` | clamps embedded timestamps to `n` |
| `--no-timestamps` | same as `--source-date-epoch=0` |
| `--remap-path-prefix=old=new` | `-ffile-prefix-map`: debug info, coverage mappings, `__FILE__`-style macros |
| `--debug-prefix-map`, `--coverage-prefix-map` | the narrower clang maps |

Objects are never LLVM bitcode, so `--lto` is unimplemented (U005W) and link output involves no LTO ordering. Identical output is checked in practice by comparing every object of two cold builds of the compiler byte for byte (only `kairo_meta.o`, which embeds build metadata, differs); see [Performance.md](Performance.md#benchmarks).

### Source text

Source files are UTF-8; the lexer's rules for encoding and identifiers are in [Lexing.md](Lexing.md#source-files).

### Not targeted

Kairo does not implement or check conformance to ISO C, ISO C++, POSIX, or coding standards such as MISRA and CERT. C and C++ code reaches Kairo through clang, and POSIX APIs are called through the FFI like any other C API.

## Platform specifics

### No platform headers in Kairo modules

FFI puts every name a header declares into the importing module's lookup, and Kairo's FFI never expands C macros ([Interop.md](Interop.md#ffi-imports)), so a macro the compiler needs is wrapped in a Native header as a real function or `constexpr`. Two consequences shape the compiler's own `Compiler/Native/` headers:

- No header a Kairo module imports includes `<windows.h>`. Its names collided with Kairo's (winnt.h's `TokenSource` enumerator against the preprocessor's `TokenSource` class), and its constants (`GENERIC_READ`, `INVALID_HANDLE_VALUE`, ...) are macros the FFI cannot name. `<windows.h>` is included only by `Compiler/Native/Win32.cpp`, which `build.py` compiles into every binary (empty off Windows), behind the plain-typed functions of `Compiler/Native/Win32.hh`: `map_readonly` / `unmap` (file mapping for `MMapRegion`), `exe_path_utf8`, `move_path` (directory-capable rename), `console_utf8`, `spawn_thread`. Every call sits under `_WIN32` or `defined!(_WIN32)`.
- C library macros get shims in `Compiler/Native/KShims.hh`: `kairo::std_out()` / `std_err()` for `stdout` / `stderr` (Darwin's `__stdoutp`, MinGW's `__acrt_iob_func`), and `kairo::neon_ld_u8` / `neon_st_u8` for `arm_neon.h`'s load/store macros.

`Lib/std/env.h` still includes `<windows.h>`, so a user program importing `std::env` on Windows gets the same name pollution.

### Windows

- Aligned allocation uses `_aligned_malloc` / `_aligned_free` on all of `_WIN32`: MinGW has no `aligned_alloc`, and memory from `_aligned_malloc` must not reach `free`.
- File writes are binary. Text-mode CRLF translation corrupted the library manifest.
- On Windows the cache root is spelled with `/` only, never `\`. A directory that cannot be renamed while a file inside it is mapped falls back to a copy.

### POSIX and the BSDs

`Compiler/Native/KThread.hh` uses its POSIX branch on every non-Windows, non-wasm host. Guarding it by `__APPLE__ || __linux__` would leave FreeBSD and NetBSD builds with no pool workers at all.

### Darwin

Darwin's `int64_t` is `long long` while `size_t` is `unsigned long` (see [Derived target facts](#derived-target-facts)). The compiler's own `build.py` writes its build-metadata section in the target's syntax (Mach-O `__DATA,__build_meta`).

### musl

musl's default thread stack is 128 KiB (glibc's is 8 MiB). Deep recursion in a worker thread (LLVM's alias analysis during ThinLTO, for one) overflows it. Every musl link of the toolchain therefore passes `-z stack-size=8388608` (`MUSL_THREAD_STACK` in `Scripts/cross_llvm.py`; `build.py` for `--target *-musl`), which musl reads from `PT_GNU_STACK` as its default thread stack. Programs that `kairo` or `kcc` link for users do not get this, matching clang; whether they should is open.

Static musl binaries spent their extra time in the kernel, on futexes. [Performance.md](Performance.md#compile-time-optimizations) records the lock-free structures that removed it.

### wasm

The target has no strict-FP support, which changes the FFI header pragmas (see [Floating point](#floating-point)). `--wasi` and `--wasi-version` are unimplemented (U005W).

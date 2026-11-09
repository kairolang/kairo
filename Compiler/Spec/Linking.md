# Linking

Kairo links with lld, linked into the compiler as a library. The linker layer in `Linker/` decides everything clang's driver would (library directories, crt objects, runtimes, argument order) and never calls a system linker or `clang -###`. The driver side of a link (when a run links, what `-o` names, where objects go) is in [Driver.md](Driver.md#outputs-and-the-object-directory).

## Linker structure

| File | Role |
|---|---|
| `Linker/API/Link.k` | The API: `plan` resolves the toolchain and renders argv without running lld; `execute` runs a planned argv; `link` does both. |
| `Linker/API/LinkJob.k` | One link's inputs and options. |
| `Linker/API/Toolchain.k` | Where everything for one target and sysroot lives ([Sysroots](#sysroots)). |
| `Linker/API/SysrootManifest.k` | Reader for `SYSROOT.toml` and the flat TOML subset it uses. |
| `Linker/API/Flavor/ELF.k`, `MachO.k`, `MinGW.k`, `COFF.k`, `Wasm.k` | `LinkJob` + `Toolchain` to one lld flavor's argv. They decide nothing the toolchain did not resolve and run nothing. |
| `Linker/API/LLDRunner.k` | The only file that runs lld: in process or through `kld`. |
| `Linker/API/LinkABI.k` | Reads each input's ABI note and refuses incompatible links. |
| `Linker/API/LinkDiag.k` | `LinkMessage` records and the parser for lld's stderr. |
| `Linker/API/HostSystem.k` | The build machine: C library flavour, system dirs, pkg-config, glibc version needs of host shared libraries. |
| `Linker/API/FS.k`, `Text.k` | File system and string helpers. |
| `Linker/Driver/kld.k` | `kld`: a port of lld's own `lld.cpp` driver, handing `lld::lldMain` the full driver table. |
| `Linker/Include/kld_drivers.hh` | Declares `lld::{coff,elf,mingw,macho,wasm}::link` at global scope. It is a C++ header because a Kairo file's body is wrapped in `namespace kairo`, where the `LLD_HAS_DRIVER` expansions would declare the wrong symbols. |

Plan and execute are separate so the driver can print the exact line under `-v` (L005V) before lld runs, which is the line wanted when a link hangs. `--print-ld-args` prints it instead of linking, and `--print-dirs` prints what the toolchain resolved.

The API never touches `DiagEngine`, so it is usable from `kld` and from tooling with no engine. The driver maps each `LinkMessage` severity onto L002F/E/W/N/R/I/V/D; Verbose and Debug print only under `-v`. lld's diagnostics are parsed from captured stderr by the `: error: ` / `: warning: ` marker (never the program name, which is `ld.lld` in process and `kld` out of process); `>>>` continuation lines stay attached to their message. Colours are off.

### In process and out of process

`LLDRunner::run` links in process unless the argv must run out of process:

- `lld::lldMain` uses one global `CommonLinkerContext`, so in-process links are serialized on a process-wide mutex. lld parallelizes internally (`--threads`), so this costs nothing.
- `CrashRecoveryContext` is enabled before the first link and never disabled. A `fatal()` in lld then unwinds back to the caller instead of exiting the compiler mid-build.
- When lld reports it cannot run again (a fatal or crash unwound out of it), the runner is poisoned: the flag latches and every later link in the process runs through `kld`. The failed link is not retried.
- An argv carrying `-mllvm` or `--plugin-opt=-<x>` always runs through `kld`, because those options rewrite the process's global `cl` state.
- `kld` gets `-flavor <f>` at `argv[1]` (read before response files are expanded) and the rest of the line in a response file. `kld` not found next to the compiler is a fatal when a link needs it.

A crash on one of lld's own worker threads has no recovery context and still ends the process; only out-of-process linking isolates that.

## Link jobs

`CompilerInstance::_link` (`Compiler/Driver/CompilerInstance.k`) builds and runs one `LinkJob` per batch:

1. Drain every thread-pool group (`wait_all`). `lldMain` is not reentrant and resets process-global state, and no object writer may still be open.
2. On MinGW targets, add `-l winpthread` when a Kairo TU imported `pthread.h` and the user named neither `winpthread` nor `pthread` (MinGW's pthreads are not in its libc).
3. Fill the job: output, `--threads`, the `kld` path, `--lto` and the `-O` level the objects were built at, and the ThinLTO cache `<cache root>/lto` when it can be created. Kairo emits no bitcode, but the vendored LLVM's lld archives are bitcode, so a program that links lld (the compiler itself) would otherwise ThinLTO-compile all of lld on every link.
4. Objects in order: each TU's objects, native objects, command-line link inputs. `add_object` drops a repeated path (two inputs sharing an import emit its object to one place). The Kairo library's objects are `lazy_objects`, linked after them as archive members (`--start-lib`/`--end-lib`), or as one `lazy_archive` on a linker without `--start-lib` (MinGW).
5. An object that was never written is L003E and the link does not run. Emission is synchronous, so this is a driver bug, not a race.
6. `Link::plan`, then `Link::execute`:
   - create the output's parent directory;
   - `LinkABI::check` ([ABI notes](#abi-notes));
   - run lld and parse its stderr; an exit status with no reported error is itself an error;
   - after a link against the glibc floor, warn once per host shared library that needs a newer `GLIBC_` symbol version, naming the glibc the program now needs to run.

The object list is exactly what the run emitted, never a directory glob: a reused `--cache-dir` can hold objects of modules that no longer exist.

An optimized build (`-O1` and above, or a `release` / `min-size` profile) links with safe identical-code folding (`--icf=safe`; `--no-icf` opts out, `Compiler/Config/Linker.k`). It is sound because every Kairo object carries an address-significance table (`-faddrsig`, `ClangBackend`, on ELF and COFF targets where clang's own driver emits one), so lld folds only functions whose address is never compared. At `-O0` it is off, since merged functions confuse a debugger.

### Flavors

| Target format | lld driver (argv[0]) | Builder | Order (as clang's driver, so lines diff against `clang++ -###`) |
|---|---|---|---|
| ELF | `ld.lld` | `ELFArgs` | options, `-o`, crt startup, crtbegin, `-L`, rpaths, objects, user libs, default libs, crtend, crt end |
| Mach-O | `ld64.lld` | `MachOArgs` | options, `-arch`, `-platform_version`, `-syslibroot`, `-o`, `-L`, rpaths, objects, user libs, `-lc++ -lSystem`, builtins |
| COFF, MinGW-w64 (`<arch>-windows-gnu`) | `ld.lld` with a PE `-m` emulation, which lld hands to its MinGW driver | `MinGWArgs` | options, `-o`, `crt2`/`dllcrt2`, crtbegin, `-L`, objects, user libs, default libs, crtend |
| COFF, MSVC (`<arch>-windows-msvc`) | `lld-link` | `COFFArgs` | options, `-machine`, `-out`, `-libpath`, objects, user libs, default libs |
| Wasm | `wasm-ld` | `WasmArgs` | options, `-o`, crt1, `-L`, objects, user libs, default libs |

Output shapes:

| Format | Default | `--shared` | `--static` |
|---|---|---|---|
| ELF | `-pie`, `Scrt1.o`, `crtbeginS.o` on Linux; `-fno-pie` gives `-no-pie`, `crt1.o` | `-shared`, `crtbeginS`/`crtendS`, no crt1 | `-static`, `crt1.o`, `crtbeginT.o`; with `-fpie`, static PIE (`rcrt1.o`, `--no-dynamic-linker`). Default libraries in one `--start-group`, because libc++, the unwinder, the builtins and libc reference each other in cycles. |
| Mach-O | `-dynamic`; no crt (dyld enters at `_main` through `LC_MAIN`) | `-dylib`, `-install_name @rpath/<file>` unless given | rejected: lld has no `-static` and libSystem is only a dylib |
| MinGW | `-Bdynamic`, `crt2.o` | `dllcrt2.o`, `-e DllMainCRTStartup`, `--enable-auto-image-base` | `-Bstatic` for every `-l` |
| MSVC | static CRT (`libcmt`, `libvcruntime`, `libucrt`); entry and subsystem inferred by lld-link | | |
| Wasm | WASI: command module with `crt1-command.o`; bare: library module with `--no-entry` | rejected (dynamic linking is emscripten's ABI) | no effect |

Further per-flavor rules:

- MinGW brackets libc++ and the unwinder `-Bstatic` in every image, as Rust and Zig do on windows-gnu: nothing on Windows installs `libc++.dll`. The CRT and Win32 libraries stay dynamic.
- MSVC options are spelled with `-`, never `/`, so a `/`-led absolute POSIX path is never mistaken for an option. Linking a CRT by name (`-l msvcrt -l vcruntime -l ucrt`) switches to the dynamic CRT. libc++ on MSVC sits on vcruntime's exception ABI (no libc++abi, no unwinder).
- Mach-O drops ELF-only options with no meaning there, diagnosing those whose silent drop would change the output.
- A bare wasm target has no libc, so no libc++ and no Kairo runtime: it links only freestanding.

`-l` takes an optional qualifier: `-l static:foo` (ELF: `-Bstatic -lfoo -Bdynamic` on a dynamic link), `-l dynamic:foo` (an error on a static link), and on Mach-O also `weak:`. A name containing `/` or ending in `.a`, `.o` or `.so` is passed as a path.

### ABI notes

Every Kairo object carries two records in a section of its own, written by `EmitIR::_abi_note` and found by byte scan, so one reader handles ELF, Mach-O, COFF objects and archive members alike:

| Record | Bytes |
|---|---|
| calling conventions | `0x7f 'K' 'A' 'B' 'I'`, version `1`, conventions (bit 0 `preserve_most`, 1 `preserve_all`, 2 `preserve_none`), LLVM major |
| global allocator | `0x7f 'K' 'A' 'B' 'I'`, kind `2`, flags (1: built without `__KAIRO_GLOBAL_ALLOCATOR_SET`, so its `Global` is `System` inlined; 2: sets the global allocator) |

LLVM documents these calling conventions as unstable across releases, so two objects that use any of them must come from one LLVM major. An object with flag 1 linked beside one with flag 2 would allocate around the program's allocator; the link is refused, naming the object to rebuild. An object without a note (C, C++, or Kairo code using no such convention) is not compared. A bitcode object holds the note bit-packed and is not checked.

## Sysroots

`Toolchain::resolve` fills a `Toolchain` from the resolved `TargetOptions` (the driver resolves the target and picks the sysroot; see [Driver.md](Driver.md#sysroot-selection)) and the `LinkerOptions`. It reads the file system and the environment and nothing else; whatever it cannot find is a `LinkMessage`, never a guess. Only ELF, Mach-O, COFF and Wasm objects link; any other object format is a fatal.

### Sysroot shapes

| Style | When | Layout |
|---|---|---|
| `manifest` | `<sysroot>/SYSROOT.toml` exists | The manifest is the authority. lld gets `--sysroot`. |
| `root` (ELF) | `<sysroot>/usr/lib` exists (`/`, a chroot) | Searched as `<root>/usr`, then `<root>`. |
| `prefix` (ELF) | anything else, e.g. `--sysroot=/usr` | The directory is the prefix. lld does not get `--sysroot`: glibc's `libc.so` is a linker script naming `/usr/lib/libc.so.6`, which lld would re-root to `/usr/usr/lib/...`. |
| `sdk` (Mach-O) | Apple targets without a manifest | With no `--sysroot` (or `/`): `SDKROOT` when it names the target's platform, then `DEVELOPER_DIR`, `/var/db/xcode_select_link`, the Command Line Tools, Xcode's default location. `xcrun` is never run. `--macos-sdk` beats `--sysroot` and the bundle. |
| MinGW | `<arch>-windows-gnu` without a manifest | First of `<sr>/<arch>-w64-mingw32`, `<sr>/usr/<arch>-w64-mingw32`, `<sr>` that holds `crt2.o` or `libmingw32.a`, so `--sysroot=/` never pulls in host ELF libraries. GCC is looked for beside it. |
| MSVC | `<arch>-windows-msvc` without a manifest | No `--sysroot`: `LIB` as vcvars sets it. With one: an xwin splat or a Visual Studio / msvc-wine tree, newest version first. |
| Wasm | wasm targets | wasi-sdk: libc and libc++ in `<sr>/lib/<arch>-<os>[-<env>]`; builtins from the resource dir or the sysroot. WASI preview 2 and emscripten are rejected. |

A manifest whose `triple` names another target, or none of whose `lib_dirs` exists, is an error.

### SYSROOT.toml

Flat TOML: strings, booleans, string arrays (which may span lines), `#` comments. Table headers are skipped and unknown keys ignored; they belong to the tools that build sysroots. `sysroot` resolves against the manifest's own directory (`"."` is that directory); every other path against the resolved sysroot.

| Key | Type | Meaning |
|---|---|---|
| `triple` | string | the target the sysroot is for |
| `llvm_version` | string | |
| `family` | string | |
| `glibc_version` | string | the glibc the sysroot's libc is (the floor); empty for other C libraries |
| `sysroot` | string | root directory, default `.` |
| `resource_dir` | string | |
| `rtlib`, `unwindlib` | string | runtime choice |
| `linker` | string | |
| `has_libcxx` | bool | |
| `static` | bool | static-only sysroot (musl): `--shared` is unavailable |
| `include_dirs`, `lib_dirs` | array | search dirs |
| `crt_startup`, `crt_end` | array | crt objects |
| `libc_link`, `libcxx_link` | array | link words for libc and libc++ (a bundle's libc++abi may be a separate archive, named here) |
| `cc_isolation` | array | the words that keep clang from discovering host headers |
| `cc_defines` | array | macros the prebuilt libc++ was built with |

### Runtime choice

| Target | rtlib | unwindlib |
|---|---|---|
| ELF | `--rtlib`, then the manifest; with `--native`, compiler-rt (the bundled libc++ was built against it); otherwise libgcc on glibc (or MinGW) when a GCC install is found, else compiler-rt | `--unwindlib`, then the manifest, else matching rtlib |
| Apple | compiler-rt only, linked when present (libSystem carries its own builtins) | libSystem |
| MSVC | vcruntime, optionally compiler-rt on top | SEH |
| Wasm | compiler-rt | `none`, or `libunwind` for `-fwasm-exceptions` |

compiler-rt is looked for under several triple spellings of the target (`_rt_triples`: the target, the manifest's triple spelled and normalized, the `unknown`, vendorless and `pc` vendor forms, and on Windows the `w64` forms), in the resource dir and in the sysroot's library dirs, where llvm-mingw and the bundled sysroots keep it. The default target's vendor spelling is chosen so that clang finds the same directory ([Driver.md](Driver.md#sysroot-selection)).

A toolchain whose libc++ sits beside clang (`<resource-dir>/../..`) rather than in the sysroot has that directory searched first, and added as an rpath on dynamic links, when it is not a system library directory.

The deployment target on Apple platforms is `<PLATFORM>_DEPLOYMENT_TARGET`, then the triple's OS version, then the SDK version. The environment beats the triple because the default triple carries the host OS version, which would make the variable dead for every host build.

Host library dirs (`LIBRARY_PATH`, the host's system dirs in `floor` and `native` modes) are added after the sysroot's own, skipping any that is already one of them.

# Build system

How the toolchain (`kairo`, `kcc` and the tools beside them) is built, staged into a relocatable tree, and packaged. Building from source as a user is `BUILD.md`. Targets, triples and CPU floors are [Portability.md](Portability.md#targets); compile-speed work is [Performance.md](Performance.md). Why the repo builds itself is [SelfHosting.md](SelfHosting.md).

0.2.0: `build.py` is the only build of the compiler. A seed release (0.2.0+) is required (`--kairo`, `$KAIRO_SEED`, `build/<host>/{N-1,release}/bin/kairo`, or `kairo` on `PATH`); the first build also builds the patched LLVM (CMake and Ninja). The toolchain targets are `kairo`, `kcc`, `kld`, `kfmt` (plus `katar`, `kparse`, `clang-diag-identity`); the staged tree holds `kairo`, `kcc`, `kld`, `kfmt`, `llvm-symbolizer`, `llvm-ar` / `llvm-ranlib` / `llvm-lib` and `lib/clang/22`, and no `clang` or `clang++` binary (kairo and kcc run clang in-process, kld runs lld in-process). `kbld` below is Stage 0's historical driver.

Two build drivers exist:

| Driver | Builds | With |
|---|---|---|
| `build.py` | Stage 1 source (the repo, marked by `.selfhosted`) | a Stage 1 compiler |
| `kbld` (`build.k`, `Extras/BuildTool`) | Stage 0-syntax source and the tools not yet migrated | Stage 0 |

`build.py` restates `build.k`'s logic for a Stage 1 compiler: the same targets, the same pre- and post-build hooks, the same linkage invariant. `kbld` cannot build Stage 1 source.

## build.py

### Source and output

| Condition | Source | Output |
|---|---|---|
| `--src DIR` | `DIR` | `build/<triple>/stage1.5/<mode>` |
| `.selfhosted` at the repo root, no `--src`/`--out`/`--print-jobs`/`--single` | the repo | the [pipeline](#pipeline) below |
| `.selfhosted`, single-tree build | the repo | `build/<triple>/stage1.5/<mode>` |
| otherwise | the repo | `build/<triple>/stage1/<mode>` |

`--out` overrides the output; `build.py` refuses an output whose `bin/` holds the compiler doing the build. The compiler is chosen as in [Seed compiler](SelfHosting.md#bootstrap).

### Targets

| Target | Entry |
|---|---|
| `kairo` | `Compiler/Driver/Kairo.k` |
| `kcc` | `Compiler/Driver/Kcc.k` |
| `kld` | `Linker/Driver/kld.k` |
| `kparse` | `Compiler/Tooling/ParseOnceTest.k` |
| `katar` | `Extras/KaTAR/KTCompress.k` (adds the `Extras/KaTAR` root) |
| `clang-diag-identity` | `Compiler/Tooling/GenClangDiagIdentity.k` |

The toolchain is `kairo` and `kcc`; only those two trigger [staging](#staged-trees). `kbld`, `kfmt`, `kals` and `kpkg` are refused until their sources are migrated.

### Pipeline

With `.selfhosted` and no single-tree flag, `build.py` runs one of two pipelines:

- `--debug`: the release compiler builds the toolchain into `build/<triple>/debug`, with the cache `build/<triple>/cache/debug`.
- release (default): on Linux the release tree is the static musl triple (`x86_64-linux-gnu` releases as `x86_64-linux-musl`), which still runs on the host. Whenever the pipeline has a target (this one included), that target's LLVM is rebuilt first if stale ([Cross LLVM](#cross-llvm)), by the seed's `kcc`; a seed without `kcc` first builds one into `build/<host>/staging`. Steps:
  1. Clear the release and staging caches.
  2. Copy `build/<t>/release` to `build/<t>/N-1` (the backup, and the seed).
  3. N-1 builds `kairo` alone into `build/<t>/staging`.
  4. The staging compiler builds the toolchain into `build/<t>/release`.
  5. Point the toolchain's `PATH` entries at it (unless `--no-path`).

  A failure at any step restores `release/` from N-1 and exits nonzero.
- `--target T` for a target this host cannot run: the host's release compiler builds `build/T/release` directly, with no staging step.

Caches are passed as `--cache-dir` so the same directories carry state once the compiler compiles incrementally.

### Cache layout

One cache per (mode, triple) build, shared by every tool it builds ([Incremental.md](Incremental.md#shared-across-graphs)):

```text
<cache>/                          build/<triple>/cache/{debug,staging,release}, or --cache-dir, or <out>/obj
  tu/                             kairo's --cache-dir for EVERY target (kairo, kcc, kfmt, kld, ...)
    kairo-cache-v<N>/<F>/objects/ the content-addressed object store
    <module path>.o               the link inputs, one per Kairo TU, shared too
    <target>_meta.o, Win32.o      each target's native inputs
  registry/                       registry.o, its stamp and log (its compile also uses tu/ as its store)
<out>/logs/<target>.log           per-target log
```

A TU's object key is its own (the toolchain fingerprint, its stream, the headers it reaches), so after `kairo` is built, `kcc` compiles only `Driver::Kcc` and links: the release pipeline's `kcc` reuses 338 of its 339 TUs from `kairo`'s, `kld` 28 of 29 ([Incremental.md](Incremental.md#measured)). The link inputs are shared as well: each is rewritten from the store whenever its own record names another key, and every run links its own object list, never a glob of the directory. Each pipeline stage's cache stays its own (`staging` and `release` are cleared per pipeline run).

### Internal generics regime

`build.py` passes the internal `-fduck-generics` to the compiler's own targets. The flag lets `<T: type>` generic parameters through: the body is emitted as an unconstrained C++ template and the C++ compiler checks each instance. CRTP mixins and large generic surfaces in `Compiler/` use it until they get real bounds (`TODO(DUCK-GENERIC)`, 119 markers; [TodoMarkers.md](TodoMarkers.md)). It is off by default and not a supported user feature (decided 2026-11-08), and is documented nowhere in the language reference.

### Visibility regime

The compiler's own targets build under the language's visibility rule: `build.py` (`tree_visibility_args`) passes `-fdefault-visibility=spec`, the compiler's default, explicitly, and no longer passes `-fdefault-visibility=pub` (the old everything-visible rule the tree used until 2026-11-08). Each top-level directory of `Compiler/` and `Linker/` that holds Kairo has a comments-only `module.k` (no `module` pin), so an unmarked declaration is `prot` to that directory's module and what another module uses is marked `pub`. The registry object takes the same flag through the same function. `-fdefault-visibility` itself stays, internal, for users and tests; a seed that predates it gets no flag.

### Compile line

One compile per target links the whole binary:

- inputs: the entry, the generated `<target>_meta.cpp` (one string of project metadata and a `built=` stamp in a named section, per object format, and the tool's version string), the registry object, clang's `cc1as_main.cpp` (so `-cc1as` jobs run in-process) and `Compiler/Native/Win32.cpp` (the only file that includes `<windows.h>`, empty elsewhere);
- `-I Compiler -I Linker` for every target, so module identity is the same in every tool;
- `--cxx-define KAIRO_VERSION_EXTERN=1`, `--threads`, `--cache-dir <cache>/tu`. The tool's version string (`<name>-0.2.0+dev.<date>`) is defined in its `<target>_meta.cpp` as `kairo_version_cstr()`, which `Native/KShims.hh`'s `version_string()` returns under that define, not as a `-D VERSION` on every TU: a define is a cc1 word, so it was in every object key and differed per tool and per day ([Cache layout](#cache-layout));
- LLVM, clang and lld headers and libraries ([Toolchain linkage](#toolchain-linkage));
- profile: debug is `--profile debug -O0 -g --debug-macros -D DEBUG --cxx-define DEBUG` (plus `-fsanitize-ub` under `--sanitize-ub`); release is `--profile release -O3 --cxx-define NDEBUG`;
- `--rpath $ORIGIN/../lib` (Linux) or `@loader_path/../lib` (macOS); on Windows the SDK and MSVC library paths found by registry and `vswhere`;
- `--native` unless `--no-native`, `KAIRO_HOST_SYSROOT` or `--target`: the vendored LLVM was built against the host glibc, newer than the bundled sysroot's. With `--native` on Linux, `-l c++ -l c++abi` come first so every libc++ symbol resolves from the shared libc++ that `libLLVM.so` uses: two copies in one process throw `std::bad_cast` before `main`;
- for a self-host tree, `-w` unless `--warnings`, and `-A R058W`: the AST node modules import each other by design;
- `--reproducible` flags when on ([Fixed point](SelfHosting.md#bootstrap)).

`--print-jobs` prints the planned clang jobs and link without building.

### Toolchain linkage

| Host | LLVM linkage |
|---|---|
| Linux, macOS | shared: one `libLLVM` and `libclang-cpp` in `lib/`, thin binaries |
| Windows | static, always; `libLLVM.dll` is unsupported |
| every cross target | static |

There is no system-LLVM fallback: the toolchain links the patched fork (custom clang PP-token injection), and a missing fork is a hard error. lld's libraries are a fixed list (`lldCommon`, `lldELF`, `lldCOFF`, `lldMinGW`, `lldMachO`, `lldWasm`); static links name the LLVM and clang component libraries explicitly.

### Registry object

Every LLVM tool links the diagnostic registry object ([Diagnostics.md](Diagnostics.md#registry)). `build.py` gets it one of three ways:

- `--registry-object PATH`: used as given.
- A self-host tree: compiled by the compiler doing the build from `build/registry/Compiler/Diagnostic/Registry.k` (written by `gen_diag.py` on every build) (declarations and bodies as one module, whose root goes first so it shadows the tree's declarations-only `Registry.k`), into `<cache>/registry/registry.o` (its `--cache-dir` is the shared `<cache>/tu`), and rebuilt only when that source, the compiler or the arguments change. The shared `build/.kbld/registry.o` is never written: it is Stage 0's.
- The repo as Stage 0 source: the prebuild runs `gen_diag.py`, writing `build/.kbld/registry.o` and `Compiler/Diagnostic/Registry.k`.

Unless `--registry-object`, `--no-prebuild`, `--print-jobs` or `--target` is given, the build first runs `Scripts/build_llvm.py` ([LLVM](#llvm)), which costs about a second on an up-to-date fork.

### Stage 1 gaps

Flags `build.k` passes that a Stage 1 build cannot express, printed by `--explain-gaps`:

| `build.k` flag | Why it is missing |
|---|---|
| `-fvisibility=hidden`, `-fvisibility-inlines-hidden` | `--cxx-flags` reaches only C/C++ inputs, never Kairo codegen |
| the deterministic FP set (`-fno-fast-math`, `-ffp-contract=off`, ...) | same; Kairo's own FP semantics apply |
| `-Xclang -vectorize-loops`, `-vectorize-slp` | same |
| `-gline-tables-only` (release) | Stage 1 has full `-g` only |
| `-flto`, LTO partitions | `--lto` is unimplemented |
| `-Wl,--no-export-dynamic` | Stage 1 does not pass `-rdynamic` |
| `-frandom-seed`; remapping the shared registry object | no Kairo spelling; the object is shared and not checked |
| `-w` | dropped on purpose: warnings stay on |
| `-fsanitize=undefined,bounds,function` (debug) | `-fsanitize-ub` is accepted but unimplemented |

### Cross targets

`--target T` builds a tree for another target on this host. Its LLVM comes from `Scripts/cross_llvm.py`, never `build/llvm`; linkage is static, and the CPU floor is `cross_llvm.FAMILIES`' entry for `T`, so the LLVM a tree links and the tree itself agree. On musl targets the link sets `-zstack-size` to the cross toolchain's thread stack size, because musl's 128 KiB default overflows. MinGW links name the Win32 libraries LLVM uses. `KAIRO_TREE_OS` tells `stage_tree.py` which OS the tree is for.

## Staged trees

`Scripts/stage_tree.py` is the post-build hook of `kairo` and `kcc` (in both `build.py` and `build.k`). It turns a build tree into a toolchain that runs with no root flags:

| Path | Contents |
|---|---|
| `bin/` | `clang-<ver>`, `lld`, `llvm-nm`, `llvm-objdump` (copies); `clang`, `clang++`, `clang-cpp`, `clang-cl` link to `clang-<ver>`; `ld.lld`, `ld64.lld`, `lld-link`, `wasm-ld` link to `lld` |
| `lib/clang/<ver>` | the clang resource dir |
| `lib/builtin`, `lib/std`, `lib/rt` | `Lib/builtin`, `Lib/std`, `Lib/rt` |
| `sysroot` | for a tree outside `build/<triple>/{debug,release}`, a link to the release tree's sysroot (`build.py`); a debug tree's is a link to the release one |

The compiler derives `--resource-dir`, `--builtins-dir` and `--std-dir` from `<exe>/../lib` when they are not given (`CompilerInstance::_discover_roots`, `Compiler/Driver/CompilerInstance.k`), and the runtime root is the builtin root's parent, so `lib/rt` must sit beside `lib/builtin`. A missing root or sysroot is a `P001W` naming the flag ([Driver.md](Driver.md#toolchain-discovery)).

A debug tree's `lib/builtin`, `lib/std` and `lib/rt` are relative symlinks into `Lib/`, so a debug compiler always sees the current library sources. A release tree copies them, and a Windows tree always copies. The resource dir and tools are copies in both. Staging is idempotent: a file is copied only when missing or older than its source, and a mirrored directory drops entries its source no longer has. The tool list is what `build_llvm.py` builds; staging never starts an LLVM build.

### Relocation

After staging, `bundle_tree()` makes the tree relocatable and gates it:

| Host | Dependencies | Search paths |
|---|---|---|
| Linux (ELF) | `ldd`; every non-system shared library copied into `lib/` | `RUNPATH` set by `patchelf` to `$ORIGIN/../lib` (`bin/`) and `$ORIGIN` (`lib/`) |
| macOS (Mach-O) | `otool -L` | install names `@rpath/<name>`, rpaths `@loader_path/../lib` and `@loader_path`, then an ad-hoc re-sign |
| Windows (PE) | imports of each `bin/` executable | none: non-system DLLs are copied beside the executables |

The run fails, and prints `NOT relocatable` instead of `OK`, on unresolved dependencies, a wrong `RUNPATH`, a dangling symlink outside `sysroot/`, or, on Linux, a binary needing a glibc above the floor. The floor gate is off unless `--glibc-floor`, `$KAIRO_GLIBC_FLOOR` or `KAIRO_HOST_SYSROOT` sets it; the glibc floor found is always reported. Logs, `liblld*.a` and draft `std` files are removed. A tree for another OS is not bundled on this host. Only the Linux path has been exercised; the macOS and Windows paths follow the tools' documented output.

## LLVM

The toolchain links a patched fork of llvm-project, the submodule `Lib/llvm-runtimes`. Its native build is `build/llvm`.

### Native build

`Scripts/build_llvm.py` configures and builds the fork with CMake and Ninja, then stages its libraries into `build/<triple>/<mode>/lib`. Configuration: `Release`, projects `clang;lld`, targets `$LLVM_TARGETS` (default `X86;AArch64;ARM;RISCV;WebAssembly`), RTTI and EH on, zlib and zstd forced on, tests, examples, benchmarks, bindings and LLVM/clang tools off. On Linux and macOS it builds one LLVM dylib that everything links, against libc++. `llvm-objdump` and `llvm-nm` are built separately when missing, because the test suite uses them on every host. Link jobs are capped by RAM on Linux (`$LINK_JOBS` overrides).

The stamp `build/llvm/.kbld-configure.sha256` hashes the host and the configure arguments. Equal stamp: Ninja always runs, since the stamp does not cover the fork's sources and only Ninja knows what changed; on an up-to-date tree it takes about a second. Different stamp: the CMake cache is dropped (a removed `-D` would otherwise persist) and the tree reconfigures, keeping objects. A build with no stamp, made by the older per-platform scripts (`Scripts/prebuild-llvm-{linux.sh,macos.sh,windows.ps1}`, which `build_llvm.py` supersedes), is adopted, except on macOS.

On Linux the fork is compiled by a copy of its own clang in `build/llvm-host`, outside `build/llvm`: with ThinLTO the static lld archives are bitcode readable only by an lld of the same or newer LLVM, and a distro clang upgrade made them unreadable to the fork's lld. It is seeded once from `build/llvm`; delete it to refresh. A first build uses the host clang only if its major version is the fork's. Windows needs Visual Studio's environment and vcpkg.

`--dry-run` prints the CMake command and the configure hash without building.

### Worktrees

The stamp's hash covers the checkout path, so a stamp copied from another checkout mismatches and triggers a rebuild; a checkout gets its own stamp from `python3 Scripts/build_llvm.py --dry-run` run inside it.

### Host sysroot

`KAIRO_HOST_SYSROOT=<dir with SYSROOT.toml>` pins a Linux toolchain's glibc floor to an old-glibc sysroot (for example `x86_64-linux-gnu-glibc2.31`) instead of the build host's. One variable, read by three consumers so they cannot drift: `build_llvm.py` configures LLVM against it (a different hash, so a full LLVM rebuild), `build.py`/`build.k` compile and link against it, and `stage_tree.py` gates on its `glibc_version`. `Scripts/host_sysroot.py` answers `--check`, `--cflags`, `--ldflags` and `--glibc`. Unset, all three use the host glibc with no gate.

### Cross LLVM

`Scripts/cross_llvm.py <triple>` builds the shipping LLVM for one target into `build/cross-llvm/<triple>/`: static zlib and zstd in `deps/prefix`, then the fork as static ThinLTO archives in `llvm/`. Every C, C++ and assembly compile goes through `kcc` (by default the seed's, `build.py find_seed`) against the vendored sysroot, so a shipped tree depends on nothing from the build host, and one Linux machine produces every target. Profile: `-O3`, ThinLTO, the target's CPU floor, `--gc-sections`, `--icf=safe`. TableGen comes from `build/llvm/bin`. The Kairo runtime (`Lib/rt`) contains mimalloc and replaces malloc in every ELF program `kcc` links, so the shipped clang and lld use it.

## Release packaging

`Scripts/package_release.py <triple>...` (or `--all`) archives each built `build/<triple>/release` tree as `kairo-<version>-<triple>.tar.xz` (Linux, BSD) or `.zip` (Windows, macOS) in `dist/<version>/`, with `SHA256SUMS`. The version is `build.py`'s `KAIRO_VERSION`. An archive holds `bin/` and `lib/` with internal symlinks kept and any symlink out of the tree resolved. `--sysroots` selects the vendored target sysroots: `separate` (default, one `kairo-<version>-sysroots.tar.xz`), `bundled` (a copy in every archive) or `none`.

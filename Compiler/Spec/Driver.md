# Driver

The driver turns a command line into a batch: it parses flags into a `CompilerInvocation`, finds the toolchain's roots and sysroot, runs each input through the pipeline (or hands it to clang), and links. The pipeline stages it calls are specified in [Pipeline.md](Pipeline.md#compilation-phases); the link it plans is specified in [Linking.md](Linking.md#link-jobs).

## Driver phases

### Entry points

| Binary | Source | Role |
|---|---|---|
| `kairo` | `Compiler/Driver/Kairo.k` | The compiler driver. |
| `kcc` | `Compiler/Driver/Kcc.k` | clang-compatible driver over the same `CompilerInstance`; see [Interop.md](Interop.md#kcc). |
| `kld` | `Linker/Driver/kld.k` | Out-of-process linker; see [Linking.md](Linking.md#linker-structure). |

### Process sequence

`main` in `Kairo.k` is deliberately thin; driver behaviour lives in `CompilerInstance` (`Compiler/Driver/CompilerInstance.k`) and the option structs in `Compiler/Config/`.

1. Scan argv by hand for `--time-passes`, `--print-stats`, `--stats-file` and `--time-trace`. The timer must be armed before `CompilerInstance` is constructed (the constructor starts the thread pool), and flags are not parsed until then. The scan only decides whether to arm; the trace path comes from the real parse.
2. Initialize LLVM (all targets, MC layers, asm parsers and printers), the process locale (`LC_CTYPE` forced to UTF-8), and the logger. The `InitLLVM` guard is a heap object destroyed last in `main`, so `llvm_shutdown` runs while lld's parallel executor is still alive.
3. Construct `CompilerInstance` from argv. Flag errors are reported here.
4. Identity exits: `--help`, `--version`, `--explain <code>`.
5. Info queries, which exit without compiling: `--print-targets`, `--print-cpus`, `--print-target-info`, `--print-dirs`, `--print-clang-args`, `--print-jobs`, `--print-from-clang`, `--print-cfg`, `--print-runtimes-revision` (the LLVM runtimes revision the compiler was built from; `<prefix>/share/kairo/runtimes/REVISION` must equal it before the sysroot generator builds anything).
6. `args_ok()`: any flag error exits 1.
7. `apply_input_options()`: `--input-encoding` other than UTF-8 is U009E; `--working-dir` changes the process directory (U010E if it cannot), before anything reads the current directory.
8. `initialize(cwd)`: report queued root warnings, build the `ImportResolver` (include dirs, macro search paths, then the `builtin` and `std` roots; see [Imports.md](Imports.md#path-resolution)), start the shared `ClangBackend` on the pool, and create the header-set cache, header index, foreign registry and `PreProcessor`.
9. `execute()` runs the batch.
10. Write the timing report, `--stats-file` and `--time-trace` outputs. An unwritable path is U023E and fails the run.

The exit status is 0 when `BatchResult::ok()` holds: no error anywhere in the batch. Warnings alone exit 0.

### Construction

`CompilerInstance` has three constructors, all ending in `_adopt`:

| Constructor | Used by |
|---|---|
| `(argc, argv)` | `kairo`. Parses with `CompilerInvocation::from_args`. |
| `(words)` | `kcc`: kairo CLI words translated from a clang command line, through the same parser. |
| `(inv)` | Programmatic callers with a built `CompilerInvocation`. The invocation is copied; `print_help` is a no-op. |

`_adopt` copies the invocation, applies it (`_apply_invocation`) when it parsed cleanly, then creates the thread pool (`--threads`, 0 = hardware concurrency, capped by `--cmax-threads`), `SourceManager`, `TokenCacheManager` and `GlobalDisambigTable`. `_apply_invocation` maps diagnostic policy onto the engine (only `pretty`, `basic` and `json` error formats are accepted; `msvc` is U021E) and then resolves the environment in this order:

1. `_check_host_flags`: `--native` with `--target` is U016E; `--native` on a non-Linux host is U017E.
2. `_use_bundled_sysroot` ([Sysroot selection](#sysroot-selection)).
3. `_absolutize_paths`: every path option made absolute against the cwd.
4. `_discover_roots` ([Root discovery](#root-discovery)).
5. `_check_sysroot`.
6. `_apply_host_system`: host include and library dirs, and `--pkg-config`.

### Batch execution

`execute()`:

1. No inputs is I004F.
2. `_plan_outputs` classifies every input and fixes the output plan ([Outputs and the object directory](#outputs-and-the-object-directory)). An unusable input stops the run before anything compiles, every one reported.
3. `_discover_includes` finds `.k` files that C/C++ inputs include (`Compiler/Driver/KairoIncludes.k`; see [Interop.md](Interop.md#kcc)).
4. `_settle_global_allocator`, then the Kairo library when linking under `--kairo-lib` ([Runtime and the Kairo library](#runtime-and-the-kairo-library)).
5. One `FrontendAction` per Kairo input, in `_kairo_order()`. Link inputs go to the link list; C/C++ sources and headers are collected for step 7. Every input runs even after an earlier one failed, as clang does; a fatal sets `aborted`, which stops what runs after the loop.
6. When linking: a second script (each script is a `main`; see [ScriptMode.md](ScriptMode.md#script-files)) or a second global allocator is an error.
7. With no errors: compile native inputs (`_compile_sources`), then the runtime when Kairo objects were emitted.
8. Drain and release every clang header set.
9. Link (`_link`) when the plan links and nothing failed; remove a temporary object directory unless `--save-temps`. A link input in a run that does not link is L006W.

The diagnostic engine is shared by the whole batch and never reset, so its final counts are the batch totals.

### Per-file stages

`FrontendAction::run` advances a `TUStage` (`Compiler/Driver/TUStage.k`) strictly forward: `Loading`, `Preprocessing`, then parse, Sema and codegen, ending in `Done` or `Failed`. Each stage gate compares the engine's error count with the count the previous input left (`errors_at_start`), so one input's errors never stop the next input's checks.

| Stage | Work | Stops here for |
|---|---|---|
| Load | `SourceManager::load_file`; failure is I005F. | |
| Preprocess | The batch-scoped `PreProcessor` walks the input's import graph once per file across the batch; `claim_fid` gives each file to the first input that reaches it. Header sets start parsing on the pool. | `--preprocess`, `--dump-preprocessed` |
| Parse | | `--syntax-only` |
| Sema | Import groups in dependency order ([Pipeline.md](Pipeline.md#sema-pass-order)). | `--type-check-only` |
| Codegen | [Codegen.md](Codegen.md#pipeline). | |

`--syntax-only` is per file: it parses its inputs and none of their imports, and drops the C++ header sets, but still preprocesses the import closure so imported macros expand. When a C/C++ input includes a Kairo file (`kairo_feeds_includes`), the Kairo inputs run past the preprocess and parse stops, because the include needs them analysed.

With exactly one Kairo input and no C/C++ input including a `.k`, the clang header sets are released after Sema, before codegen fans out.

### Outputs and the object directory

`_plan_outputs` decides, once per batch:

- `-o` names one output: the executable or library when the run links, the single object (or `.s`, `.ll`, `.bc`, `.pch`) otherwise. `-o` naming a directory is I004F. Under a non-linking run, more than one output with `-o` is I004F; the count is `(kairo + source inputs) × emitted kinds + headers`, taken before any TU writes.
- The run links when it is not `-c`, does not stop before codegen, and has at least one Kairo, source or link input. A build of headers alone writes their `.pch` files and stops. The default link output is `a.out`.
- Objects go to `--cache-dir` (kept). Without it, a linking run uses a temporary directory removed after the link, or `<output>.kobj` under `--save-temps`; a non-linking run uses the working directory.
- With `--emit` naming kinds besides `obj` on a linking run, objects are still produced for the link; the listed kinds are outputs, written beside the executable when the object directory is temporary.
- `--emit-scope=graph` (default) writes objects for every Kairo file the run reaches; `inputs` writes them for the command line's own files only, as `clang -c` does.
- Two C/C++ inputs with one stem (or two headers with one file name) are U013E; clang silently overwrites, Kairo refuses. A Kairo entry TU of the same stem writes `<stem>.k.<ext>` instead and does not clash.

### Runtime and the Kairo library

The runtime is the C and C++ sources directly in `<runtime root>/rt`, where the runtime root is the parent of the builtin directory. They compile on Kairo's own hand-built cc1 line (`ClangBackend::native_invocation`), not clang's driver, because they are part of Kairo's code and must be built as Kairo TUs are. Runtime objects never take `-o`. The batch starts the runtime compile on the pool as soon as the first action reaches Sema (`prestart_runtime`) and joins it after codegen.

Runtime objects are cached under `<cache root>/rt`, keyed by the exact cc1 line and a fingerprint: the compiler binary, every file in `rt/`, and the vendored mimalloc sources, each stamped with size and mtime. Objects are copied in and out of the cache, never linked from it.

`--kairo-lib` (set by `kcc` when it links) links builtin, std and the runtime lazily from a library built once per target and option set, under `<cache root>/lib/<triple>-<hash>`. The hash covers the compiler path, the triple, the target, codegen and optimization words, debug info, the builtin and std directories, and `--global-allocator-set`. A `manifest` lists the objects, an optional archive, and every source with its mtime; any change rebuilds. The library is built into a private directory and renamed into place, so concurrent builds never see half of one. Its objects are linked lazily ([Linking.md](Linking.md#link-jobs)), so a run's own copy of builtin wins.

The cache root is `$KAIRO_CACHE_DIR`, else `$XDG_CACHE_HOME/kairo`, else `~/.cache/kairo`, else `%LOCALAPPDATA%/kairo`, with `/` separators on every host. No root means nothing is cached.

## Flags

### Flag registry

Every `kairo` flag is defined in `register_kairo_flags` (`Compiler/Command/FlagRegistry.k`); `--help` is generated from that table, so this document does not list flags. The parser is `Command` (`Compiler/Command/Command.k`), its results are `ParsedArgs` (`Compiler/Command/ParsedArgs.k`), and the typed option structs are built from them in `Compiler/Config/` (`FrontendOptions`, `LanguageOptions`, `TargetOptions`, `CodeGenOptions`, `LinkerOptions`, `PreprocessorOptions`, `DiagnosticOptions`, gathered in `CompilerInvocation`).

Flag kinds (`FlagKind`, `Compiler/Command/FlagUtils.k`):

| Kind | Shape |
|---|---|
| `Bool` | presence |
| `String`, `Path` | one value; `str_c` restricts it to a choice list |
| `I32`, `F64` | number with optional bounds |
| `StringList` | repeatable; each occurrence appends |
| `PathList` | the positional inputs |
| `Feature` | `-f<name>` / `-fno-<name>`, read as -1 unset, 0 off, 1 on |

Config limits (`define_cfg`) are stored under the key `c:<name>` and spelled `--c<name>=<value>` (for example `--cmax-errors=50`).

Accepted spellings: `--flag`, `--flag=value`, `--flag value`, short flags and clusters (`-abc`), joined short values (`-ofile`), and long single-dash flags for the prefixes `W O f m X s D A E F g I L l Z` (`-Wall`, `-O2`, `-march=...`, `-DFOO=1`). `--` ends options. `-` is the stdin input. `-x
<lang>` (`--language`) tags every following input until the next `-x`, with
clang's positional semantics (`Command::tag_positionals_with`, `ParsedArgs::file_langs`); `-x none` restores classification by extension.

Several letters keep Kairo meanings that differ from clang's: `-I` is a Kairo import root and a clang `-I`; `-D` is a Kairo macro, never forwarded to clang (`--cxx-define` is clang's); `-E`, `-A`, `-F`, `-W<code>` are the deny, allow, forbid and warn diagnostic policies ([Diagnostics.md](Diagnostics.md#codes)).

Groups in the registry: identity and info queries, input, output, target, build mode, optimization, reproducible builds, language semantics (hard switches), language feature toggles (`-f`), defines and config, warnings and diagnostics, BCIR/AMT internals, incremental compilation, module system, linking, per-platform link options (Darwin, Windows, WASM, embedded), testing, verbosity, developer dumps, and compiler limits.

### Unimplemented flags

A flag the parser accepts but nothing consumes is registered with `cmd->mark_unimplemented(key)` at the end of `register_kairo_flags` (`c:<name>` for config limits, the bare name for features). Setting one emits U005W ("accepted but not yet implemented; it has no effect"), once per flag, and `--help` renders it with `[not implemented]`, so a flag never appears to do something it does not. The entry is removed in the same change that wires the flag's consumer. An unknown key in the list is ignored, so a typo there cannot abort the compiler.

An internal flag, one that exists for the compiler's own build rather than for users, is registered with `cmd->mark_hidden(key)` (same key forms). It parses and works as usual; `--help` leaves it out. The first is `-fduck-generics` (decided 2026-11-08: off by default so user code gets real bounds; `build.py` passes it for the compiler's own targets).

`--help-hidden` lists the flags a user is not offered or cannot use yet: the internal ones, tagged `[internal]`, and the not-implemented ones, tagged `[not implemented]` (these also appear in `--help`). It exits like `--help`.

The list covers: the BCIR, pass-pipeline, regalloc, generics and type-info dumps and verifiers; the module cache (incremental compilation phase 1 is implemented: `--cache-dir`, [Incremental.md](Incremental.md)); the test runner (`--test*`); `--host` and `--cxx-abi`; `--borrow-check`, `--amt-*`, `--panic-handler`, `--cfg`, `--edition` (validated, never read); the language gates with no check point (`--no-assert`, `--no-eval`, `--no-generics`, `-fverify-interfaces`, `-fstrict-null`, ...); sanitizers, coverage, PGO, XRay, LTO (objects are never bitcode) and other codegen features with no cc1 spelling or no runtime archive in the bundled sysroots; WASI and some wasm feature flags; `--ctab-width`, `--diag-cascade`; and config limits nothing enforces.

### Pipeline-control flags

The primary action is one `FrontendActionKind` (`Compiler/Config/Frontend.k`), chosen by the highest-priority flag given:

| Priority | Flag | Action |
|---|---|---|
| 1 | `--preprocess`, `--dump-preprocessed` | `Preprocess` |
| 2 | `--syntax-only` | `SyntaxOnly` |
| 3 | `--type-check-only` | `TypeCheckOnly` |
| 4 | `-c` | `EmitObjOnly` |
| 5 | `-S`, or `--emit=asm` alone | `EmitAsm` |
| 6 | `--emit=llvm-ir` alone | `EmitLLVMIR` |
| 7 | `--emit=llvm-bc` alone | `EmitLLVMBC` |
| default | | `EmitObj` (compile and link) |

`--emit` takes a comma list of `obj`, `asm`, `llvm-ir`, `llvm-bc`; any other item is U003E. `-S` beside an explicit `--emit` adds `asm`; alone it replaces `obj`. Each TU writes `<module>.o/.s/.ll/.bc` under the object directory.

Dump flags are orthogonal to the action and fire at fixed points:

| Flag | Output | Point |
|---|---|---|
| `--dump-preprocessed`, `--print-tokens`, `--print-macros`, `--print-imports` | token stream, macros, import graph and overlays | after preprocessing |
| `--print-ast=tree\|flat\|canonical`, `--print-symbols` | AST, frozen symbol tables | after parsing |
| `--print-sema` | every resolved binding | after the checks, before any lowering |
| `--print-lowered` | the same dump after the `Lower/` passes | after lowering |
| `--print-emit-plan`, `--print-cxx`, `--emit-headers=<dir>` | EmitPlan, C++ preamble text, interop headers | after Sema; headers only without errors |
| `--print-cg`, `--print-ir` | codegen token stream, generated C++ | in codegen (forces one worker) |
| `--print-panic-sets` | every `Panic<T, E...>` instance | after Sema |

Each dump covers every TU, including builtin and std. Its exact pinning to Sema phases is specified in [Pipeline.md](Pipeline.md#compilation-phases).

### Tuning flags

What were environment variables during the compile-time and parallel-Sema measurements are flags, so a run is reproducible from its command line:

| Flag | Meaning |
|---|---|
| `--sema-threads=N` | threads that run Sema over the import groups; 0 (default) is `--threads`, 1 is the one-thread loop (the byte-identity baseline) |
| `--codegen-threads=N` | threads of the per-TU C++ compiles; 0 (default) is `--threads`; always capped at the TU count |
| `--interface-pch=auto\|on\|off` | the per-flavour interface PCH ([Codegen.md](Codegen.md)); `auto` (default) builds it only for 2+ TUs and 1 MiB of Kairo; under `--verbose` a failed build's clang diagnostics are shown |
| `-fno-shared-header-set` | one clang parse per header list instead of one for the union ([Interop.md](Interop.md#header-sets)) |

`--print-stats` also prints the memory probes (arena bytes by kind, largest TU, header-set AST bytes, per-stage Sema arena growth) and, with `-finfer-purity`, the inferred const / pure counts ([Performance.md](Performance.md)). `NO_COLOR`, `KAIRO_DEBUG_FORCE_ICE` (test hook) and `KAIRO_CLANG_TRACE_DIR` stay environment variables.

### Progress

`--progress=auto|always|never|lines` (`Driver/Progress.k`, engine in `Native/KProgress.hh`) reports how far a run is, on stderr. Three phases report: `parse` (one unit per file), `sema` (one per file, counted when its import group finishes) and `codegen` (one per Kairo TU). Counters are atomics bumped when a task ends.

| Value | Behaviour |
|---|---|
| `auto` (default) | a pinned status line whenever stderr is a terminal and `TERM` is not `dumb` (`NO_COLOR` and `--verbose` do not turn it off); nothing otherwise, so piped output and the lit tests see none |
| `always` | the pinned line regardless of those checks (a console that cannot take ANSI sequences still gets none) |
| `never` | nothing |
| `lines` | one plain line per event, below |

The pinned line is `[sema 212/338] Sema/Type/CallTyping.k  0:09`, redrawn about every 100 ms from one thread, never wrapped. In the codegen phase it reads `[codegen 41/338, 297 reused]`: `done` includes the TUs the incremental object cache already held ([Incremental.md](Incremental.md)). The line is erased before the diagnostics print and stays off until the last one is out, so diagnostic text never shares its row; it is also gone before the codegen post-pass prints, and on an ICE. On Windows the driver enables virtual-terminal processing on the console (`Native/Win32.cpp`), and falls back to `never` where that fails.

`lines` writes events to stderr, each one whole line. The format is stable:

```
@progress phase=<parse|sema|codegen> done=<n> total=<n> [reused=<n>] [file=<path>]
```

- The prefix `@progress ` starts no diagnostic (those begin with a path or `kairo:`). Every other stderr line is not an event.
- Keys come in this order, separated by one space. `reused` appears on `codegen` lines only (always, 0 when nothing was reused). `file` is last and runs to the end of the line (it may hold spaces); it is the file that just finished, relative to the working directory when under it, and is absent on the event that opens a phase and on `reused` updates.
- A phase opens with `done=0`. `done` is monotonic within a phase and reaches `total` when the phase ends. A run with several inputs repeats each phase per input.
- A `sema` event names the first file of the import group that finished and advances `done` by the group's size, so `done` can step by more than one.

On a terminal `build.py` runs every compiler that lists the flag in `--help-hidden` on a pty with `--progress=always`, passes the compiler's own redraws through to the terminal and keeps every other stderr line in the log; without a pty (Windows) it passes `--progress=lines` and draws its own line from the events. Off a terminal it passes `--progress=lines` and only the log is written. An unknown value is U001E.

### Clang flag translation

`Compiler/Command/FlagTranslator.k` is the only file that spells a clang flag for a Kairo option. Each concern (target, codegen, optimization, debug info, warnings, preprocessor, language standard) is one function that decides once what was asked for and writes it in a requested spelling:

| Spelling | Consumer |
|---|---|
| cc1 | Kairo's own TUs and the ffi header sets (`ClangBackend::_cc1_common`). |
| Driver | C/C++ inputs handed to clang's driver, and the target-defaults probe. |
| reverse (`from_driver`) | `kcc`: a clang command line parsed with clang's own option table into Kairo words, which then go through the ordinary parser. |

Order is part of the contract: cc1 takes the last of a repeated option, so broad switches come before specific ones and `--mllvm` words come last. `--print-from-clang -- <clang argv>` prints the reverse translation. The header-search roots are not flags and are not spelled here: they are a property of the sysroot, owned by `ClangBackend` ([Interop.md](Interop.md#clang-integration)).

## Toolchain discovery

### Layout

A staged tree ([BuildSystem.md](BuildSystem.md#staged-trees)) runs with no root flags. Everything is found relative to the toolchain prefix, the directory above the resolved binary (`<prefix>/bin/kairo`; a symlink on `PATH` still finds its tree):

| Root | Default | Flag |
|---|---|---|
| clang resource dir | highest-versioned `<prefix>/lib/clang/<ver>` holding `include/stddef.h` (versions compare numerically) | `--resource-dir` |
| builtin tree | `<prefix>/lib/builtin` | `--builtins-dir` |
| standard library | `<prefix>/lib/std` | `--std-dir` |
| bundled sysroots | `<prefix>/sysroot/<triple>` | `--sysroot` |
| out-of-process linker | `<prefix>/bin/kld[.exe]` | |
| sysroot generator inputs | `<prefix>/share/kairo/sysroot` | `$KAIRO_SYSROOT_SHARE` |
| sysroot generator cache | `<toolchain cache root>/sysroot` | `$KAIRO_SYSROOT_CACHE` |

### Root discovery

`_discover_roots` fills the roots that were not given. A flag always wins. A given `--resource-dir` keeps its older meaning too: its `builtin/` and `std/` are used when they exist, before the layout. No builtin root is searched under `--no-prelude` (or `--freestanding`), and no std root under `--no-stdlib`.

A root still missing is P008W with a P008N naming the flag to pass. The warnings are queued and reported by `initialize()`, so `--help`, `--version` and the info queries never print them. Without the builtin tree every lang item is unbound and `string` does not resolve; the warning keeps that from reading as a Sema bug.

### Sysroot selection

Without `--target`, the build compiles for `get_default_target_triple()`, the host's architecture and OS with a C library the toolchain ships; the table per host and the reason the Linux vendor is always `unknown` are in [Portability.md](Portability.md#targets). An explicit `--target` is canonicalized once, first in `_apply_invocation` (`_canonical_target`): a glibc version (`-glibc2.28`, Zig's `.2.28`) moves to `TargetOptions::glibc`, where only the sysroot lookups read it, and a macOS triple with no OS version gets its deployment floor (11.0 arm64, 10.15 x86_64; `Toolchain::with_os_floor`), since clang's default has no thread-local storage. `_effective_triple` then applies `Toolchain::canonical_triple` so clang, codegen and the linker see one float ABI; the default target on 32-bit Arm Linux is hard-float for the same reason. `-m32`/`-m64` rewrite the triple's architecture, as clang does.

The sysroot is chosen by `_use_bundled_sysroot`:

- `--native`: the host is the sysroot (`/`); the bundle for the host's C library still supplies libc++ and compiler-rt.
- `--target`, or no `--sysroot`: `<prefix>/sysroot/<triple>`, or the one directory there naming the same target in another spelling (same arch, sub-arch, OS and environment). A bundle that is not a directory, lacks `SYSROOT.toml`, or has a malformed one is P007E.
- `--sysroot` without `--target`: that directory, as given.
- No bundle and no `--sysroot`, for `--target` and for the default target alike (a macOS or BSD archive ships no root for its own host): the sysroot generator's cache, then its `ensure` in-process; macOS and MSVC roots are staged from the installed SDK plus the shipped overlay ([SysRoot.md](SysRoot.md#22-state-after-p743-p746-2026-11-09-host-roots-on-first-use-one-canonical---target)) (`_sysroot_from_generator`; [SysRoot.md](SysRoot.md#8-cli-and-driver-hook)). A refusal is P009E and exit 2; `--no-sysroot-build` makes the missing root that refusal instead of a build. Without a share tree to build from, the run keeps the P008W below. The order is: a bundled `<prefix>/sysroot/<name>`, then the cache's `by-name/<name>` (also reported by `--version`, which never builds), then the build; the build is skipped for `--help`, `--version`, `--explain` and the info queries. A build that fails is P010E and exit 3. When a sysroot's `SYSROOT.toml` records `clang_triple`, clang's `-triple`, the driver probe and C/C++ `--target` use it instead of the name's triple. The target-spelling grammar, the stages and the cache layout are [SysRoot.md](SysRoot.md); the user-facing view is the `ksys` page of the website docs.

`_check_sysroot` then reports P008W when no sysroot was found or the given one is not a directory, unless `--freestanding` asked for none or `--macos-sdk` stands in for one.

`_apply_host_system` sets `TargetOptions::host_mode`:

| Mode | When | Effect |
|---|---|---|
| `floor` | Linux host, same arch, no `--target`, `--sysroot` or `--freestanding` | Host system include and library dirs are searched after the bundled sysroot, so a header or library the sysroot lacks comes from the host while libc never does. `LIBRARY_PATH`, `NIX_CFLAGS_COMPILE` and `NIX_LDFLAGS` are read. |
| `native` | `--native` | The host's C library, headers and libraries, with the bundled libc++ and compiler-rt. |
| hermetic | anything else | No host dir and no host environment search path. A cross build is the same on every machine. |

`--pkg-config <name>` runs pkg-config and routes its words: `-I`/`-isystem` to `--ffi-include`, `-D`/`-U` to `--cxx-define`/`--cxx-undefine`, `-L`, `-l`, `-pthread`, `-Wl,` to the link. A `-I` or `-L` naming a host system dir is dropped (it would come before the sysroot). With `--target` it requires `PKG_CONFIG_SYSROOT_DIR` or `PKG_CONFIG_LIBDIR` (U018E); a failed query is U019E.

## Native inputs

### Classification

`classify_input` (`Compiler/Driver/InputKinds.k`) is the one classifier for command-line inputs and runtime sources. It uses clang's own type table (`clang::driver::types`), so an input clang would accept is classified as clang classifies it and `-x` takes clang's type names. Kairo adds `.k` and the link inputs clang has no type for.

| Class | Inputs | Handling |
|---|---|---|
| `Kairo` | `.k`, or `-x kairo`/`-x k` on a `.k` | `FrontendAction` |
| `Source` | C, C++, ObjC/ObjC++, OpenCL, HLSL, CUDA, HIP, LLVM IR, preprocessed, assembly (`.s`, `.S`), `.pcm`, `.ast`, `.pch` | clang's driver ([below](#compilation-through-clangs-driver)) |
| `Header` | clang's precompile-only types (`.h`, `.hh`, `.hpp`, ...) | precompiled to `<file>.pch`; never linked |
| `LinkInput` | `.o`, `.obj`, `.lib` (clang's `TY_Object`), `.a`, `.so`, `.so.N...`, `.dylib`, `.dll`, `.tbd`, `.res` | the link |
| `Unsupported` | a clang type clang does not compile (Fortran), or `-x kairo` on a non-`.k` | U011E |
| `Unknown` | no recognized extension and no `-x`; `-` without `-x` | U011E, naming `-x` |
| `BadLanguage` | `-x` naming no language | U011E |

An unknown extension is an error, a deliberate deviation from clang, which treats it as an object and lets the linker print an unreadable message. `Path::extension()` keeps the dot; `input_ext` strips it once, and every comparison uses the bare spelling.

`-x kairo` is refused on any extension but `.k`: module naming, `--emit-headers` paths and the object-directory mirror all derive from the `.k` stem.

### Compilation through clang's driver

`ClangJobs` (`Compiler/Interop/Clang/ClangJobs.k`) compiles every `Source` and `Header` input. It builds a clang driver argv (`FlagTranslator::to_driver` plus the backend's sysroot words), calls `Driver::BuildCompilation`, and runs each planned job itself:

| Job | Execution |
|---|---|
| `clang -cc1` | In process: `CompilerInvocation::CreateFromArgs`, a fresh `CompilerInstance` over the backend's shared VFS, and `ExecuteCompilerInvocation` with the `#include "foo.k"` hook ([Interop.md](Interop.md#kcc)). |
| `clang -cc1as` | In process, through clang's own `cc1as_main`, compiled into every Kairo binary (`Native/Cc1As.hh`). An `.S` is a cc1 `-E` job followed by a cc1as job. |
| any other tool | Spawned with `Command::Execute`, exactly as clang's driver would (`ptxas` and `fatbinary` for CUDA, the offload tools for HIP, an external `as` under `-fno-integrated-as`). |

The jobs are read from `Compilation::getJobs()`; `Command::Execute` is used only for external tools, because clang forces out-of-process execution whenever a compilation has more than one job. Every argv carries `-c`, `-S`, `-E` or `-fsyntax-only`, so clang never plans a link: Kairo's linker is the only linker. `-disable-free` is cleared, because this process keeps compiling after the job. `-mllvm` words are kept and re-parsed per job, as under clang. On a hermetic `--target` build, the words clang's driver took from `CPATH`, `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH` and `OBJC_INCLUDE_PATH` are removed. Each cc1 job has its own `ClangDiagAdapter`, so a C/C++ input's errors render like Kairo's and one bad input does not fail the next.

Defaults for a C/C++ input are clang's: the translator forwards only Kairo flags the user gave, plus `--target`, which is always the build's effective triple (the driver would otherwise pick the host's, and the objects would not match the Kairo objects in the same link). `--cxx-flags` words are appended last and reach only the C/C++ compiles. `--c-std` (default `c17`) and `--cxx-std` (default `c++23`) select the standard per input language. IR and preprocessed inputs get no header roots.

### Actions and output naming

Native inputs follow the batch's action: `-c` writes `.o`, `-S` `.s`, `--emit` kinds `.ll`/`.bc` (one driver run per kind), `--preprocess` runs `-E` to stdout or `-o`, and `--syntax-only` and `--type-check-only` both run `-fsyntax-only`. An input with no such phase (IR and `.i`/`.ii` under `--preprocess`, IR under a check-only run) is skipped with U012W, as clang does. Outputs are named `<object dir>/<stem>.<ext>`; a header's is `<file>.pch` (`foo.h` writes `foo.h.pch`, so it never collides with `foo.c`), kept in the working directory when the object directory is temporary. `--print-clang-args` prints each native input's planned cc1 line after the Kairo line; `--print-jobs` adds the planned link (kcc's `-###`).

### Open decisions

`-E` stays the diagnostic deny flag. A clang user typing `kairo -E foo.cc` gets "deny foo.cc"; `--preprocess` is the preprocess spelling. Moving `-E` to the clang meaning, with `--error=<code>` long-only, is an open design question.

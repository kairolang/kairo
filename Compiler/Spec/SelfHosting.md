# Self-hosting

How the Kairo compiler comes to compile itself: the stages, the bootstrap and its fixed-point proof, and the migration of the compiler's source from Stage 0 syntax to Stage 1 syntax. How the resulting tree is built is [BuildSystem.md](BuildSystem.md).

Status: `Compiler/`, `Linker/` and `Extras/KaTAR` are Stage 1 source, the compiler builds itself, Stage 0 is retired (its last tree is in the repository history), and a prebuilt release (0.2.0+, `kairo` and `kcc`) is the required seed: a build without one is not possible. Still ahead: Tether, virtual interfaces, async, compile-time evaluation of calls, parser poison nodes and fully safe AST pointers (before 0.3.5), incremental phase 2 (0.2.5).

## Stages

Each stage is a start marker: the point at which its work begins, not a release that closes the previous one.

| Stage | What it is | Built by |
|---|---|---|
| Stage 0 | The C++ transpiler. No semantic analysis; codegens one C++ file. Frozen; kept only to bootstrap. | clang |
| Stage 1 | The compiler in `Compiler/`, `Linker/`, `Extras/KaTAR`: lexer, preprocessor, parser, Sema, codegen through clang. Complete when it compiles a migrated copy of its own source and that binary passes the suite and reaches the [fixed point](#bootstrap). | Stage 0, then itself |
| Stage 1.5 | API migration: real builtin and std APIs (`std::time`, `std::sync`, a full std) until the compiler depends on nothing from C++'s std. Until then C++ std uses stay `cxx::std::` through ffi. | Stage 1 |
| Stage 2 | Hardening and refactoring, real optimization passes over an SSA graph, Tether. | Stage 1 |

A tree built by a Stage 1 compiler from migrated sources lands in `build/<triple>/stage1.5/<mode>` when `build.py` builds a single tree ([build.py](BuildSystem.md#buildpy)). The directory name follows an older use of "Stage 1.5" for the self-built binary.

Stage 1 self-hosts: the repo's `Compiler/`, `Linker/` and `Extras/KaTAR` are Stage 1 syntax ([Switch-over](#switch-over)).

### Principles

1. The migrated tree is a build artifact. It is produced by: pinned source, migration scripts, patch series. It is never edited in place as the record of a fix ([Patches and hand edits](#migration)).
2. Bottom-up by the import DAG. A layer passes a phase before the layer above it starts that phase ([Layer order](#migration)).
3. Differential where possible: the same source compiled by two compilers must behave the same ([Not implemented](#migration)).
4. A compiler gap (Stage 1 rejects valid migrated code, or miscompiles it) is fixed in the compiler with a regression test under `Tests/`, never patched around in the migrated tree.
5. Every phase has an exit criterion. No phase starts with known failures in the one below it.

### Semantic independence

Every diagnostic produced at codegen time falls in exactly one bucket:

| Bucket | Meaning | Where it is tracked |
|---|---|---|
| A | A Kairo bug: wrong C++ emitted (bad spelling, invalid syntax), a crash, or Kairo's own Sema reporting late (an error under `-c` that `--type-check-only` does not report). | The issue tracker |
| B | Clang rejected something Kairo's Sema accepted. Kairo should have diagnosed it first, with a Kairo code. Every `CL001E` a user sees is a Kairo failure. | The table below |

The [objects phase](#migration) keeps Kairo and clang diagnostics in separate bucket lists for this reason. Bucket B empty is a Stage 2 goal: Kairo's Sema performs every check, and clang never diagnoses Kairo code. Open Bucket B entries:

| Clang reports | Kairo should |
|---|---|
| `static assertion failed` (`assert static` is emitted as C++ `static_assert`) | Evaluate static asserts in Kairo's evaluator: non-dependent at type-check, dependent per instance. Clang decides today. |
| (nothing yet; the emitter leaves deduction to clang CTAD) | Deduce class-template and alias-template arguments from constructor arguments in Sema instead of emitting the bare template. |

Resolved: copy of an imported non-copyable C++ object (now `SC001E`), an emitter cast that dropped qualifiers (now a C-style cast), and, in Bucket A, an enum argument at a C++ call and an explicit instantiation forcing every member.

## Bootstrap

### Seed compiler

The compiler a build uses is, in order: `--kairo`, `$KAIRO_SEED`, `build/<host>/release/bin/kairo` (on Linux the release triple's tree first, see [Release pipeline](BuildSystem.md#buildpy)), `kairo` on `PATH` (`find_kairo`, `build.py`). The seed whose `kcc` builds LLVM is `build/<host>/N-1/bin/kairo`, then `release`, then `PATH` (`find_seed`). `build.py` refuses an output directory that holds the compiler doing the build: replacing a binary under a running compile kills it.

Stage 0 builds Stage 1 from a clean checkout only through the last commit whose `Compiler/` is Stage 0 syntax; after that, a Stage 1 binary is the seed.

### Fixed point

Self-hosting is proven by three builds from one migrated tree with one flag set:

| Build | Compiler | Output |
|---|---|---|
| A | Stage 1 (built by Stage 0) | a self-built compiler |
| B | A | a self-built compiler |
| C | B | a self-built compiler |

B and C must be bit-identical (binary and every object). A and B may differ only in embedded support paths (sysroot, resource dir, builtin library), which name the tree each compiler runs from. The recorded proof had B == C on `bin/kairo` and all 327 objects, and identical `.text` in every object of A and B. Any difference between B and C means the compiler's output depends on which compiler built it: a miscompile, to be found before anything else.

Bit-identity requires the output to be a function of (source tree, compiler, flags) only. `build.py --reproducible` (opt-in; the `fixedpoint` and `reprocheck` phases always pass it) adds:

| Flag | Removes |
|---|---|
| `--source-date-epoch` (`--source-date-epoch` arg, else `$SOURCE_DATE_EPOCH`, else the source tree's HEAD commit time, else 0) | the build date in `VERSION` and in the `built=` stamp of `*_meta.cpp` |
| `--remap-path-prefix` for the repo root, source root and output dir (in that order; the later, longer prefix wins), and the same maps as `-ffile-prefix-map` for C/C++ inputs | absolute paths |
| `*_meta.cpp` generated under `--out/gen` | a shared `build/.gen` raced by two builds |
| Linux `--build-id none`; macOS `-no_uuid`; Windows `/Brepro /INCREMENTAL:NO` | linker-generated ids |

`--threads` does not change bytes. The `reprocheck` phase checks the precondition: the same Stage 1 compiler builds the same tree twice (all threads, then one) and the results must match. A fixed-point diff is not trusted until `reprocheck` passes. Reproducible debug info names `/kairo-root`, `/kairo-src`, `/kairo-out`, so a debugger cannot find sources; a debug build keeps real paths unless asked.

Gaps in the flag set are listed by `build.py --explain-gaps` ([build.py](BuildSystem.md#buildpy)): the shared registry object is not remapped, and Kairo has no `-frandom-seed` spelling.

### Switch-over

The switch replaces `Compiler/`, `Linker/` and `Extras/KaTAR` with the migrated tree at a frozen commit whose phases are all green, then reruns the suite comparison and the fixed point on the result.

- Since the switch, `build.py` always builds the repo itself as a self-host tree (a `.selfhosted` marker file used to signal this; it is gone) ([build.py](BuildSystem.md#buildpy)).
- `kbld` and `build.k` are Stage 0's build and cannot build Stage 1 source. `build.py` is the build of record for the compiler; tools whose sources are not migrated (`kbld`, `kpkg`) are refused by it.
- Stage 0 becomes bootstrap-only: frozen, no further changes.

### Seed chain

Design intent, not implemented: Stage 0 releases stay permanently downloadable, and the first seed is the last Stage 0 release before self-hosting. A file in the repo lists the seed chain in linear order (tag or URL plus checksum). A new entry is added only when the compiler's own source uses a change that seed N-1 cannot compile, so a compiler change that uses a new language feature in `Compiler/` needs a seed bump first. CI pins the newest entry and never pulls "latest".

A later step, also unimplemented: build LLVM with `kcc` and the Kairo sysroot, then replace clang's `SourceManager.cpp` in the fork with a Kairo port, making `kairo`/`kcc` mandatory to build LLVM.

## Migration

The compiler's source was moved from Stage 0 syntax to Stage 1 mechanically, and `TODO(<CATEGORY>)` markers record the interim choices still to decide ([TodoMarkers.md](TodoMarkers.md)). `Scripts/Migration/` keeps the three helpers the build and the test suite still use. The rules that governed the move hold for any source change: never relax Stage 1's rules to make code pass, and preserve behaviour where Stage 0 and Stage 1 differed at run time.

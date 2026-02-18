# kbld — Build Tool Specification v0.2

## Overview

`kbld` is a C++23 build tool for Kairo projects. Single header dependency: `toml++`. Reads `build.toml`, resolves the build graph, invokes `kairo` per target, tracks staleness, regenerates `compile_commands.json` on every run, and embeds binary metadata.

---

## Config Format — `build.toml`

```toml
[project]
name    = "kairo"
version = "0.1.0"
author  = "Dhruvan Kartik"
license = "Apache-2.0"

[workspace]
skip_dirs = ["build", "libs", "private"]   # dirs to exclude from compile_commands scan

[build]
compiler = "kairo"     # path or name of kairo binary, default "kairo"
mode     = "release"   # "release" | "debug", overridden by --debug/--release CLI flags

[[target]]
name    = "kairo"
entry   = "toolchain/Driver/Main/kbld.kro"
type    = "binary"          # "binary" | "static" | "shared"
includes = [".", "toolchain"]
links    = []               # -L dirs
libs     = []               # -l libs
deps     = []               # other target names, determines build order
defines  = ["NDEBUG", "MY_FLAG=1"]          # becomes -DMY_FLAG=1 after --
ld_flags = ["-Wl,--export-dynamic"]         # linker flags, passed after --
cxx_sources = ["toolchain/ffi/glue.cpp"]    # extra C++ files passed to kairo
cxx_passthrough = []                         # anything else after --

[[target]]
name     = "vial"
entry    = "vial/vial.kro"
type     = "binary"
includes = [".", "vial"]
deps     = ["kairo"]
defines  = ["VIAL_BUILD"]
```

---

## CLI Interface

```
kbld [command] [options]

Commands:
  build  [targets...]    Build all or specified targets (default if no command given)
  clean  [targets...]    Remove build artifacts for targets, or all if none specified
  test   <file.kro>      Compile and run a test file (requires fn Test() -> i32)
  deps   <file.kro>      Print resolved dependency tree for a file
  index                  Regenerate compile_commands.json only, no build
  install [prefix]       Copy binaries to prefix/bin (default: /usr/local/bin)

Options:
  --debug                Force debug mode for all targets
  --release              Force release mode for all targets
  --verbose              Pass --verbose to kairo, echo all commands
  --jobs <n>             Max parallel jobs (default: std::thread::hardware_concurrency())
  --dry-run              Print commands, don't execute
  --emit-ir              Pass --emit-ir to kairo for all targets
  --emit-ast             Pass --emit-ast to kairo for all targets
  --keep-going           Don't stop on first failure
```

---

## Directory Layout

```
build/
  <arch>-<system>-<abi>/
    release/
      bin/           # output binaries
    debug/
      bin/
  .gen/              # generated: _meta.cpp, .rc files, test runners
  .shared/
    tests/           # test files with injected main()
  .cache/
    deps/            # cached --deps JSON, keyed by entry path hash
    state.json       # per-target build state
compile_commands.json  # always at project root, regenerated every run
```

---

## Kairo Invocation

Constructed per target:

```
kairo <entry>
  -o<output_dir>/bin/<name>
  -I<include>            (one per entry in includes[])
  -L<link_dir>           (one per entry in links[])
  -l<lib>                (one per entry in libs[])
  --release | --debug
  [--verbose]
  [--emit-ir | --emit-ast]
  [-- 
    -D<define>           (one per entry in defines[])
    <ld_flag>            (one per entry in ld_flags[])
    <cxx_source>         (one per entry in cxx_sources[])
    <cxx_passthrough>    (one per entry in cxx_passthrough[])
  ]
```

The `--` separator is only emitted if at least one of `defines`, `ld_flags`, `cxx_sources`, or `cxx_passthrough` is non-empty. Do not add `-std=c++23`, `-O3`, `-Wall`, or anything Kairo already injects.

---

## compile_commands.json — Regenerated Every Run

Generated at project root before any build step. Three entry types:

**C++ files** (`.c`, `.cc`, `.cpp`, `.cxx`, `.h`, `.hh`, `.hpp`) — scanned recursively from project root, skipping `skip_dirs`:
```json
{
  "directory": "<cwd>",
  "arguments": [
    "clang++", "-std=c++23", "-O3", "-w",
    "-I<include>",
    "-D<define>",
    "<file>"
  ],
  "file": "<relative_path>"
}
```
Include dirs and defines come from the first target in `build.toml`.

**Non-entry `.kro` files** — all `.kro` files not listed as a target `entry`, using first target's flags:
```json
{
  "directory": "<cwd>",
  "arguments": [
    "-I<include>"
  ],
  "file": "<abs_path>"
}
```

**Target entry `.kro` files** — one per target, using that target's own flags:
```json
{
  "directory": "<cwd>",
  "arguments": [
    "-I<include>"
  ],
  "file": "<abs_path>"
}
```

This matches the format your existing `compile_commands.json` uses exactly. The C++ entries get the full clang++ invocation; the kairo entries get includes only (kairo-lsp reads these).

---

## Incremental Build / Staleness

Per-target check before invoking kairo:

1. Load `build/.cache/state.json`
2. Check mtime of `entry` file
3. If entry mtime changed since last build, re-invoke `kairo <entry> --deps 2>/dev/null`, parse stdout for `{"dependencies": [...]}`, cache result to `build/.cache/deps/<sha256_of_entry_path>.json`
4. Check mtime of every file in the cached deps list
5. Check mtime of every file in `cxx_sources`
6. If any input is newer than the output binary → rebuild
7. On successful build, write updated mtimes and output binary mtime to `state.json`

**Dep parsing**: scan stdout for the substring `{"dependencies":`, extract from there to the closing `}`. Don't care about diagnostics on stderr.

---

## Build Ordering

1. Build DAG from `deps = [...]` in each `[[target]]`
2. Topological sort (Kahn's algorithm)
3. Cycle → print cycle and exit 1
4. Execute in waves: targets with all deps satisfied run in parallel up to `--jobs` limit
5. Use `std::jthread` + `std::counting_semaphore<>` for the job pool

---

## Binary Metadata Embedding

kbld generates `build/.gen/<target_name>_meta.cpp` from `[project]` and passes it as a `cxx_source` automatically (no user config needed):

**Unix:**
```cpp
__attribute__((section(".build_meta"), used))
static const char kBuildMeta[] =
    "name=kairo|version=0.1.0|author=Dhruvan Kartik|license=Apache-2.0|built=<ISO8601>";
```

**Windows:** Generate `build/.gen/<target_name>.rc`, compile with `rc.exe`, inject `.res` into link via passthrough.

The generated file is added to `cxx_sources` for the target internally before command construction. User never needs to touch it.

---

## Test Runner — `kbld test <file.kro>`

1. Strip comments (single-line `//` and block `/* */`), scan for `fn Test() -> i32`
2. If not found: error and exit 1
3. Copy file to `build/.shared/tests/<filename>`
4. Append:
```
fn main() -> i32 {
    return Test();
}
```
5. Compile with debug mode (or release if `--perf`), output to `build/.gen/test_run`
6. Execute, print stdout/stderr between horizontal rules (`─` × terminal width)
7. Exit with test binary's exit code

---

## Build State — `build/.cache/state.json`

```json
{
  "targets": {
    "kairo": {
      "entry_mtime": 1739800000,
      "dep_mtimes": {
        "/abs/path/to/dep.kro": 1739799000
      },
      "cxx_source_mtimes": {
        "toolchain/ffi/glue.cpp": 1739798000
      },
      "output_mtime": 1739800100
    }
  }
}
```

Use `output_mtime` not a hash — faster, sufficient for local builds.

---

## Error Handling

| Condition | Behavior |
|---|---|
| Target build failure | Print target name + kairo output, exit 1 (unless `--keep-going`) |
| Cycle in dep graph | Print cycle path, exit 1 |
| Missing `entry` file | Error before invoking kairo, exit 1 |
| Malformed `build.toml` | Print toml++ error with line/col, exit 1 |
| `--deps` returns no JSON | Warn, skip dep staleness check, rebuild unconditionally |
| `compile_commands.json` write fails | Warn and continue, don't block build |

---

## Out of Scope (v0.1)

- Per-TU incremental C++ compilation (Kairo handles its own TUs)
- Package downloading (that's `vial`)
- Remote/distributed build cache
- Watch mode
- `--config` flag conflict with Kairo's own `--config` (kbld always reads `build.toml`, no ambiguity)

---


### `kbld line <file.kro> [start:end]` — IR Line Extraction

Invokes `kairo <file> --emit-ir --verbose -I<includes...>` using the first target's includes. Processes stdout:

1. Strip everything before the last `#define __KAIRO_CORE_CXX__ ... #endif` header block
2. Strip everything after the last `#endif`
3. Strip ANSI escape codes
4. Build a `map<filepath, vector<line>>` by tracking `#define "path"` markers and `#line N` directives — Kairo emits two `#line 1` blocks per file; the second one (after the include guard section) is the actual code, so reset the line buffer on the second occurrence
5. Match `file` argument against map keys by suffix
6. Parse range as `start:end`, `start-end`, or single line; default to full file
7. Extract lines, filter empty, write to a temp `.cpp` file, run `clang-format -style=file`, print result

If `clang-format` fails or isn't present, print the raw extracted code.

---

### `kbld test <file.kro> [--perf] [--compile-only]`

`--compile-only`: compile the test binary but don't execute it. Equivalent to the original `compile` command mode.

---

### CLI Options Table Addition

```
  --perf               (test) compile in release mode instead of debug
  --compile-only       (test) compile but don't run the test binary
```

---

### compile_commands.json — Windows MSVC path

On Windows (`_WIN32` defined at kbld compile time), C++ file entries use:
```json
["cl.exe", "/nologo", "/std:c++latest", "/MT", "/w",
 "/Isource", "/EHsc", "/DNDEBUG", "<file>"]
```
Include dirs from the first target use `/I<path>` syntax. On all other platforms use `clang++` with `-I`.

---

### `[hooks]` — Pre/Post Build Shell Commands

```toml
[[target]]
name = "kairo"
entry = "toolchain/Driver/Main/kbld.kro"
# ...
pre_build  = "python scripts/gen_version.py"   # runs before kairo invocation
post_build = "python scripts/sign_binary.py"   # runs after successful build
```
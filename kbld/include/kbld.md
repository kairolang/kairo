# kbld_lib API Reference

Automatically available in `build.kro` via `-include kbld.hh`. No import needed.

---

## Environment

Query the build environment kbld sets before running your script.

```
fn target_name()  -> string   // name of the current target being configured
fn build_mode()   -> string   // "release" or "debug"
fn triple()       -> string   // e.g. "x86_64-linux-gnu"
fn platform()     -> string   // "linux" | "macos" | "windows"
fn arch()         -> string   // "x86_64" | "aarch64" | "wasm32"
fn project_root() -> string   // absolute path to directory containing build.kro
fn out_dir()      -> string   // absolute path to output binary directory
fn build_dir()    -> string   // absolute path to build/
fn compiler()     -> string   // path to the kairo compiler binary
fn kbld_version() -> string   // kbld version string
fn num_jobs()     -> i32      // number of parallel jobs
fn is_release()   -> bool     // build_mode() == "release"
fn is_debug()     -> bool     // build_mode() == "debug"
fn env(key: string) -> libcxx::optional::<string>  // getenv, nullopt if unset
```

---

## Logging

All logging goes to stderr. stdout is reserved for the JSON blob emitted by `Project`.

```
fn log::info(msg: string)   -> void   // blue   [build.kro] prefix
fn log::ok(msg: string)     -> void   // green  [build.kro] prefix
fn log::warn(msg: string)   -> void   // yellow [build.kro] prefix
fn log::error(msg: string)  -> void   // red    [build.kro] prefix, does not exit
```

---

## Process Execution

### `RunResult`

Returned by all `run` variants.

```
struct RunResult {
    exit_code:  i32;
    stdout_str: string;
    stderr_str: string;
    success:    bool;   // exit_code == 0
}
```

### Functions

```
fn run(args: vec::<string>) -> RunResult
```
Run a command, capture stdout and stderr. Never aborts on failure.

```
fn run_or_fail(args: vec::<string>) -> RunResult
```
Same as `run` but prints stderr and calls `exit(1)` if the command fails.

```
fn run_in(dir: string, args: vec::<string>) -> RunResult
```
Run a command with a working directory override.

```
fn run_env(args: vec::<string>, env: libcxx::unordered_map::<string, string>) -> RunResult
```
Run a command with extra environment variables merged in.

```
fn which(name: string) -> libcxx::optional::<string>
```
Find a binary in PATH. Returns `nullopt` if not found.

**Example**
```
var r = run(["cmake", "-S", "llvm", "-B", "build", "-G", "Ninja"]);
if (!r.success) {
    log::error("cmake failed: " + r.stderr_str);
}

var ninja = which("ninja");
if (!ninja.has_value()) {
    log::error("ninja not found");
}
```

---

## Filesystem

```
fn path_exists(path: string) -> bool
fn is_file(path: string)     -> bool
fn is_dir(path: string)      -> bool
fn mkdir(path: string)       -> void   // mkdir -p semantics
fn read_file(path: string)   -> string
fn write_file(path: string, content: string) -> void
fn join_path(parts: vec::<string>) -> string
fn abs_path(path: string)    -> string   // resolves relative to KBLD_ROOT
fn glob(pattern: string)     -> vec::<string>
```

`glob` supports `**/*.ext` patterns. Results are sorted. Non-matching patterns return an empty vec.

**Example**
```
var sources = glob(project_root() + "/src/**/*.cpp");
for src in sources {
    log::info("found: " + src);
}
```

---

## Cache

Persistent key-value store at `build/.kbld/cache.json`. Survives across kbld invocations. Use it to avoid re-running expensive operations like LLVM builds.

```
fn cache_get(key: string)              -> libcxx::optional::<string>
fn cache_set(key: string, val: string) -> void
fn cache_has(key: string)              -> bool
fn cache_stale(key: string, paths: vec::<string>) -> bool
```

`cache_stale` returns `true` if any file in `paths` is newer than when `cache_set` was last called for `key`, or if the key has never been set.

**Example**
```
var marker = build_dir() + "/lib/libLLVM.so";

if (!cache_has("llvm_built") || cache_stale("llvm_built", [marker])) {
    run_or_fail(["ninja", "-C", build_dir() + "/llvm"]);
    cache_set("llvm_built", "1");
}
```

---

## Target

Builder pattern. Chain setters, pass to `Project::target()`.

### Constructor

```
Target(name: string)
```

### Setters — single value

```
fn Target::entry(path: string)       -> ref!(Target)   // required: entry .kro file
fn Target::kind(v: string)           -> ref!(Target)   // "binary" | "static" | "shared" (default: "binary")
fn Target::include(path: string)     -> ref!(Target)   // -I flag
fn Target::link_dir(path: string)    -> ref!(Target)   // -L flag
fn Target::lib(name: string)         -> ref!(Target)   // -l flag
fn Target::dep(name: string)         -> ref!(Target)   // dependency on another target name
fn Target::define(def: string)       -> ref!(Target)   // -D flag, e.g. "VERSION=L\"1.0\""
fn Target::ld_flag(flag: string)     -> ref!(Target)   // raw linker flag
fn Target::cxx_source(path: string)  -> ref!(Target)   // extra .cpp file passed to kairo
fn Target::passthrough(arg: string)  -> ref!(Target)   // raw arg passed after --
fn Target::pre_build(cmd: string)    -> ref!(Target)   // shell command run before build
fn Target::post_build(cmd: string)   -> ref!(Target)   // shell command run after successful build
```

### Setters — batch

```
fn Target::includes(v: vec::<string>)     -> ref!(Target)
fn Target::link_dirs(v: vec::<string>)    -> ref!(Target)
fn Target::libs(v: vec::<string>)         -> ref!(Target)
fn Target::deps(v: vec::<string>)         -> ref!(Target)
fn Target::defines(v: vec::<string>)      -> ref!(Target)
fn Target::ld_flags(v: vec::<string>)     -> ref!(Target)
fn Target::cxx_sources(v: vec::<string>)  -> ref!(Target)
fn Target::passthroughs(v: vec::<string>) -> ref!(Target)
```

**Example**
```
var t = Target("kairo")
    .entry("Toolchain/Driver/Main/kairo.kro")
    .includes(["Toolchain", "Lib/bootstrap/lib-helix"])
    .define("VERSION=L\"0.1.0\"")
    .dep("kbld")
    .ld_flag("-Wl,--export-dynamic")
    .cxx_source("Toolchain/ffi/glue.cpp")
    .pre_build("python3 scripts/gen_version.py");
```

---

## Project

Top-level config. Collects targets and global settings. Emits JSON to stdout automatically when it goes out of scope at the end of `main()`. Do not call `emit()` manually under normal usage.

Copy is disabled. Only one `Project` per `build.kro`.

### Constructor

```
Project(name: string)
```

### Setters

```
fn Project::version(v: string)              -> ref!(Project)
fn Project::author(v: string)               -> ref!(Project)
fn Project::license(v: string)              -> ref!(Project)
fn Project::compiler(v: string)             -> ref!(Project)   // kairo binary path or name
fn Project::mode(v: string)                 -> ref!(Project)   // "release" | "debug"
fn Project::skip_dir(v: string)             -> ref!(Project)   // exclude from compile_commands scan
fn Project::skip_dirs(v: vec::<string>)     -> ref!(Project)
fn Project::target(t: Target)               -> ref!(Project)
```

### Destructor behaviour

`Project` emits JSON on destruction unless:
- `emit()` was already called manually
- The destructor is running due to an exception (`std::uncaught_exceptions() > 0`)

In the exception case stdout stays empty and kbld fails cleanly.

**Full example**
```
fn main() -> i32 {
    var p = Project("kairo")
        .version("0.0.1")
        .author("author name")
        .license("CC-BY-4.0")
        .compiler("kairo")
        .mode("release")
        .skip_dirs(["build", "libs", "private"]);

    p.target(Target("kairo")
        .entry("Toolchain/Driver/Main/kairo.kro")
        .includes(["Toolchain", "Lib/bootstrap/lib-helix"])
        .define("VERSION=L\"kairo-0.1.1+rc.250306\""));

    p.target(Target("kbld")
        .entry("Toolchain/Driver/Main/kbld.kro")
        .include("Toolchain")
        .define("VERSION=L\"kbld-0.1.0+rc.250306\"")
        .dep("kairo"));

    return 0;   // Project destructor fires here, JSON emitted to stdout
}
```
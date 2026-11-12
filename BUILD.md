# Building Kairo from Source

Kairo is self-hosted: the compiler in `Compiler/` is written in Kairo and is built by a previous release of itself. Since 0.2.0 this is the only way to build it.

> **Building without a seed compiler is not possible.** You need a prebuilt Kairo release (0.2.0 or newer, which ships `kairo` and `kcc`) to compile this tree. There is no supported path that starts from a plain C++ toolchain: the old C++ bootstrap compiler (Stage 0) is retired and cannot build the current source. Its last tree is kept, for history only, on the `archive/kairo-0.1.2-stage0-bootstrap` branch.

> **Just want to use Kairo?** Skip this guide and grab a release from the [release page](https://github.com/kairolang/kairo/releases). Build from source only to work on Kairo itself or to get unreleased changes.

---

## 1. Requirements

- **A seed Kairo release** (0.2.0+) for your host, unpacked anywhere. Its `kairo` compiles the tree, and its `kcc` (a clang drop-in) compiles the bundled LLVM fork on the first build.
- **Python 3** (the build driver is `build.py`).
- **git**.
- **CMake** and **Ninja** (used once, to build the patched LLVM fork and its dependencies).
- **About 30 GB of free disk** for the first build (LLVM), and plenty of RAM: a parallel build of the compiler peaks around 3–4 GB, LLVM's own build more.

You do not need a system Clang, GCC, libc++ or LLVM: the seed's `kcc` and bundled toolchain do the compiling, and the patched LLVM fork is built from the submodule. A system LLVM is never used.

The seed also provides `llvm-ar` / `llvm-ranlib` for the LLVM build. Put the seed's `bin/` on your `PATH`:

```bash
export PATH="/path/to/kairo-0.2.0/bin:$PATH"
kairo --version
```

---

## 2. Clone the repository

```bash
git clone https://github.com/kairolang/kairo/
cd kairo
git submodule update --init --recursive   # the patched LLVM fork, musl, mingw-w64, ...: large
```

---

## 3. Build

The first build compiles the patched LLVM fork before the compiler. This is a long, one-time compile; later builds reuse it.

**Release toolchain** (the normal build):

```bash
python3 build.py --release kairo kcc
```

This is a two-stage bootstrap: the seed builds a staging compiler from the source, and the staging compiler builds the release toolchain. The result lands in `build/<triple>/release/` (for example `build/x86_64-linux-musl/release/` on Linux, a static musl build), and the previous release there is kept as `build/<triple>/N-1/`. On success `build.py` points the `kairo` and `kcc` links on your `PATH` (`~/.local/bin`) at the new toolchain; pass `--no-path` to leave `PATH` alone.

By default the seed is, in order: `build/<host>/N-1/bin/kairo`, `build/<host>/release/bin/kairo`, then `kairo` on `PATH`. On a fresh checkout that is the release you unpacked; to name it explicitly:

```bash
python3 build.py --release --kairo /path/to/kairo-0.2.0/bin/kairo kairo kcc
```

**Debug build** (the edit/test loop when working on the compiler):

```bash
python3 build.py --debug kairo kcc
```

Output: `build/<host-triple>/debug/bin/` (for example `build/x86_64-linux-gnu/debug/bin/kairo`). Debug builds are compiled by your release compiler, keep debug info and reuse the incremental object cache, so a rebuild after a small change only recompiles what changed.

**macOS and Windows hosts.** The compiler is developed and tested on Linux; the release archives for macOS and Windows are cross-built from a Linux host. Building from source on macOS or Windows works, but is newer: those hosts build against the SDK or bundled sysroot instead of the machine's C library (`--no-native` is implied), the LLVM step is the slow one, and not everything in the test suite has run there yet. Please report what breaks.

**Other targets in the toolchain:** `kld` (linker), `kfmt` (formatter), `ksys` (sysroot generator), `katar`, `kparse`, `clang-diag-identity`:

```bash
python3 build.py --release kairo kcc kld kfmt ksys
```

**Cross builds** (a toolchain that runs on another platform):

```bash
python3 build.py --release --target aarch64-linux-musl
```

Useful options: `-j N` (parallel jobs), `--print-jobs` (show the compile and link commands without building), `--cache-dir DIR` (the incremental object cache), `--compiler-flag FLAG` (pass a flag to every `kairo` invocation). `python3 build.py --help` lists them all.

---

## 4. Validate

```bash
cat > hello.k <<'EOF'
import std::io

fn main() -> i32 {
    var x = 5
    var y = 10
    io::println(f"Hello, world! Sum of {x} and {y} is {x + y}")
    return 0
}
EOF
kairo hello.k -o hello && ./hello
```

To run the compiler's test suite (LLVM `lit`, built with the LLVM fork):

```bash
build/llvm/bin/llvm-lit Tests -s
```

`lit` tests the most recently built compiler; set `KAIRO_BIN=/path/to/kairo` to pick one.

---

## 5. Editor support

The language server is `kals`. It is a separate tool built from this tree; the editor extensions only start it.

**Build and install the server:**

```bash
python3 build.py --release kairo kcc kals
```

This puts `kals` beside `kairo` in `build/<triple>/release/bin/` and, like `kairo` and `kcc`, links it on your `PATH` (`~/.local/bin`) unless you pass `--no-path`. Check it:

```bash
kals --version        # kals (Kairo language server)
```

A release archive already contains `kals` in its `bin/`; with that `bin/` on `PATH` there is nothing to build.

`kals` reads a project's entry points from `kairo_compile.json` at the project root. For this tree, write it with:

```bash
python3 build.py --emit-compile-json
```

A file that no entry reaches, or a directory with no `kairo_compile.json`, is checked on its own.

**Install an editor client.** The clients live in [kairo-lsp](https://github.com/kairolang/kairo-lsp/). Each finds `kals` on `PATH`; none needs configuration.

- **VS Code:** install the Kairo extension from the [VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=KSF.kairo), or build the `.vsix`:

  ```bash
  git clone https://github.com/kairolang/kairo-lsp/
  cd kairo-lsp/vscode
  npm install
  npm run build
  npx @vscode/vsce package
  code --install-extension kairo-*.vsix
  ```

  To use a `kals` that is not on `PATH`, set `kairo.kals.path` in `settings.json`.

- **Zed:** clone `kairo-lsp`, then run "zed: install dev extension" from the command palette and pick its `zed/` directory. Semantic highlighting is off in Zed by default; turn it on for Kairo in `settings.json`:

  ```json
  { "languages": { "Kairo": { "semantic_tokens": "combined" } } }
  ```

- **Neovim 0.11+:** clone `kairo-lsp` and put its `nvim/` directory on the runtimepath (`vim.opt.rtp:prepend("~/kairo-lsp/nvim")`). The plugin builds its parser the first time a Kairo file is opened, so it needs a C compiler. `:checkhealth kairo` reports what it found.

- **Any other editor:** start `kals` with no arguments; it speaks LSP on its standard input and output.

The server's options and what each client draws are in the [kals manual](https://www.kairolang.org/docs/toolchain/kals/).

---

## Troubleshooting

**`no seed: no build/<host>/{N-1,release}/bin/kairo and no kairo on PATH`.** `build.py` found no compiler to start from. Unpack a Kairo release and put its `bin/` on `PATH`, or pass `--kairo /path/to/kairo`.

**The seed is too old.** The tree may use language features newer than your seed. Use the latest release as the seed; if the tree is ahead of every release, build the newest release's source first and use that compiler as the seed.

**macOS: "cannot verify this app is free of malware" when running a downloaded release.** Release binaries aren't notarized yet. Clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /path/to/kairo-0.2.0
```

**macOS / Windows targets need the platform SDK.** Kairo never ships Apple's SDK or Microsoft's MSVC/Windows SDK. On macOS it uses the installed SDK (`xcode-select --install` if `xcrun --show-sdk-path` fails); on Windows, the installed Visual Studio / Windows SDK. Cross-compiling to those targets needs an SDK you supply with `--sysroot`.

**The first build seems stuck.** It is compiling LLVM; that takes a long time once. `build/` logs each step.

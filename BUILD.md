# Building Kairo from Source

Kairo has two compilers:

- **Stage 0** the current compiler, written in C++. Transpiles Kairo to C++. This is what you build first. It does **not** require LLVM.
- **Stage 1** the self-hosted compiler, written in Kairo (work in progress). Building it requires the Stage 0 compiler **and** the LLVM submodule.

Most users only need Stage 0. If you just want to compile and run `.k` files, build Stage 0 and stop there.

> **Prefer prebuilt binaries?** Skip this entire guide and grab a release from the
> [release page](https://github.com/kairolang/kairo/releases). Build from source only
> if you need the latest unreleased changes or are developing Kairo itself.

---

## 1. Requirements

Stage 0 requires:

- **Clang 18 or newer** (libstdc++ is **not** supported you must use Clang with libc++)
- **libc++** and **libc++abi**
- **xmake** (build system)
- **git**

Stage 1 additionally requires the LLVM submodule (pulled separately, see §5).

The VSCode extension additionally requires **Node.js** and **npm**.

---

## 2. Install dependencies

All platforms need **Clang 18+** with libc++ (see Requirements). Each section below shows how to get a satisfying toolchain.

### Linux

**Arch / Manjaro**

Arch's `clang` is current (well past 18), so no version pinning is needed.

```bash
sudo pacman -S git clang libc++ libc++abi lld cmake ninja xmake
```

**Ubuntu / Debian**

Clang 18 is the minimum; newer is fine, `clang++ --version` should report 18 or higher, if so you can skip the next step, just make sure you have `libc++` and `libc++abi` installed. If you need to install Clang 18.

The distro Clang is often older than 18 or defaults to libstdc++, so install from LLVM's apt repo:

```bash
wget https://apt.llvm.org/llvm.sh
chmod +x llvm.sh
sudo ./llvm.sh 18
sudo apt-get install -y libc++-18-dev libc++abi-18-dev git
# make clang-18 the default clang/clang++
sudo update-alternatives --install /usr/bin/clang   clang   /usr/bin/clang-18   100
sudo update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-18 100
```

**Fedora / RHEL**

Ensure `clang --version` reports 18+. Older RHEL ships an older toolchain — you may need a newer LLVM module (`sudo dnf module install llvm-toolset:latest`) to meet the minimum.

```bash
sudo dnf install -y clang libcxx-devel libcxxabi-devel git cmake ninja-build
```

Then install xmake (all distros):

```bash
curl -fsSL https://xmake.io/shget.text | bash
```

### macOS

Install the LLVM toolchain and xmake via Homebrew:

```bash
brew install llvm xmake
```

Then make Homebrew's Clang available on your PATH (Apple's bundled Clang works too, but Homebrew LLVM is recommended for libc++ feature support):

```bash
echo 'export PATH="'"$(brew --prefix llvm)"'/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Windows

Install xmake (PowerShell):

```powershell
irm https://xmake.io/psget.text | iex
```

Clang/MSVC toolchain: install **Visual Studio** with the "Desktop development with C++" workload, or **LLVM for Windows** from [releases.llvm.org](https://releases.llvm.org/). xmake will detect the toolchain automatically.

---

## 3. Clone the repository

```bash
git clone https://github.com/kairolang/kairo/
cd kairo
git checkout archive/beta-helix-0.0.1
```

Pull submodules. **For Stage 0 only**, this is a fast clone (no LLVM):

```bash
git submodule update --init --recursive
```

> If you later build Stage 1, you must re-run `git submodule update --init --recursive`
> after `git checkout canary` the canary branch pulls in the LLVM submodule, which is large.

---

## 4. Build the Stage 0 compiler

```bash
xmake
```

That's it no flags needed. xmake reads the build configuration and produces a
self-contained compiler. Output lands in `build/release/<platform>/bin/`: `kairo` and `kbld`.

### Add to PATH (recommended)

**Linux / macOS:**

```bash
export PATH="$PATH:$(ls -d $(pwd)/build/release/*/bin)"
```

Add that line to your `~/.bashrc` or `~/.zshrc` to make it permanent.

**Windows (PowerShell):**

```powershell
$binPath = (Get-ChildItem -Directory ".\build\release\*\bin").FullName
[Environment]::SetEnvironmentVariable("Path", "$env:Path;$binPath", "User")
```

(PowerShell only. For Command Prompt, add it via System Properties → Environment Variables.)

### Validate

Create `test.k`:

```kairo
fn main() -> i32 {
    var x = 5;
    var y = 10;
    std::print(f"Hello, world! Sum of {x} and {y} is {x + y}");
    return 0;
}
```

Compile and run:

```bash
kairo test.k
```

---

## 5. Build the Stage 1 compiler (optional, in development)

Stage 1 is self-hosted and requires Stage 0 (from §4) plus the LLVM submodule.

```bash
git checkout canary
git submodule update --init --recursive   # pulls LLVM this time large download
kbld                                       # must be on PATH, or use ./build/release/<platform>/bin/kbld
```

You can run test files whose entry point is `fn Test() -> i32 { ... }`:

```bash
kbld test Compiler/Lexer/Lexer.k
```

---

## 6. VSCode Extension (optional, recommended)

VSCode is currently the only editor with LSP support and `.k` syntax highlighting.

```bash
git clone https://github.com/kairolang/kairo-lsp/
cd kairo-lsp
npm install
npm run build --omit=dev
npx vsce package
```

This produces a `.vsix` file. In VSCode: **Extensions** tab → **⋯** menu → **Install from VSIX…**

> **Configure the extension before opening any `.k` file.** Otherwise it will repeatedly
> prompt for the Kairo path.

### Debugging

With the extension installed, use:

- **Run Kairo File** runs and attaches the debugger
- **Run Kairo File with Args** prompts for comma-separated args (e.g. `arg1,arg2,arg3`)

Both work with `fn main()` or `fn Test()` entry points.

> **Warning:** with `fn Test()`, VSCode redirects to a temporary file during debugging.
> Breakpoints work, but **edits aren't saved back to your original file** re-running the
> debugger resets everything. Use `fn main()` for active development.

---

## Troubleshooting

**macOS: "cannot verify this app is free of malware" when running a downloaded release binary.**
Release binaries aren't yet notarized. Clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine ./kairo
```

(This does not affect source builds only binaries downloaded from the release page.)

**Build fails with `libstdc++` / `use of undeclared identifier 'requires'` / constexpr errors.**
Your Clang is defaulting to libstdc++ or an older C++ standard. Confirm `clang++ --version`
reports 18+ and that libc++ is installed. Kairo requires Clang with libc++ and C++23.

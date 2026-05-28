# Building Kairo from Source

---

## Manual Setup

### 1. Clone the repo

```bash
git clone https://github.com/kairolang/kairo/
cd kairo
git submodule update --init --recursive # this will take a while since it clones the entire LLVM repo, but it's necessary
```


### 2. Build the Stage 0 compiler (this branch is for the Stage 1 compiler (WIP), but since all the code is in kairo you need the stage0 compiler to build it)

> [!NOTE]
> You can also use the prebuilt binaries from the [release page](https://github.com/kairolang/kairo/releases)
> or follow these instructions to build the Stage 0 compiler from source.

```bash
git checkout archive/beta-helix-0.0.1
xmake
```

## 2.1 Add the stage0 compiler to PATH (recommended)

**Linux / macOS:**
```bash
echo 'export PATH="$PATH:'$(ls -d $(pwd)/build/release/*/bin)'"' >> ~/."${SHELL##*/}rc"
```
This resolves the build path and appends it to your shell config (`~/.bashrc`, `~/.zshrc`, etc.) automatically.

**Windows (PowerShell):**
```powershell
$binPath = (Get-ChildItem -Directory ".\build\release\*\bin").FullName
[Environment]::SetEnvironmentVariable("Path", "$env:Path;$binPath", "User")
```
This adds the build path to your user PATH variable. Powershell only, if you're using Command Prompt, you'll need to add it manually via System Properties.

### 2.2 Optional: Build the Stage 1 compiler (in development)

```bash
git checkout canary
kbld  # kbld must be in path otherwise use `./build/release/<platform>/bin/kbld` directly

# you can also test files that contain `fn Test() -> i32 { ... }` as the entry point, but note that this is not the standard entry point for Kairo programs.
kbld test Compiler/Lexer/Lexer.k
```

Output lands in `./build/release/<platform>/bin/`: `kairo` and `kbld`.

---

## VSCode Extension (optional but recommended)

Right now VSCode is the only editor with LSP support and syntax highlighting for `.k` files.

### Build and install

```bash
git clone https://github.com/kairolang/kairo-lsp/
cd kairo-lsp
npm install
npm run build --omit=dev
npx vsce package
```

This produces a `kairouage-<version>.vsix` file.
Install it in VSCode (you can do that by heading to the Extensions tab, clicking the three dots, and selecting "Install from VSIX...").

**NOTE:** If you open a `.k` file before configuring the extension, it will annoy you with popups asking for the Kairo path. So ideally, configure the extension first before opening any Kairo files.

---

## Debugging

Set breakpoints directly in VSCode and use:
- `Run Kairo File`: runs and attaches the debugger
- `Run Kairo File with Args`: prompts for arguments in comma-separated format (e.g. `arg1,arg2,arg3`)

Both work with `fn main() -> i32 { ... }` or `fn Test() -> i32 { ... }` as your entry point.

> [!WARNING]
> If you're using `fn Test()`, VSCode redirects you to a temporary test file during debugging. Breakpoints still work, but **edits won't be saved back to your original file**: re-running the debugger resets everything. Use `fn main()` for active development.
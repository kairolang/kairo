# Building Kairo from Source

## Quick Install (recommended)

```bash
# Unix (macOS, Linux)
curl -sSL https://github.com/kairolang/kairo/blob/canary/helix-0.1.1+bc.251007/Scripts/install.sh | bash

# Windows (PowerShell)
curl -sSL https://github.com/kairolang/kairo/blob/canary/helix-0.1.1+bc.251007/Scripts/install.sh | iex
```

The script will walk you through everything: install location, permissions, and optionally the VSCode extension.

> [!NOTE]
> The installer hasn't been fully battle-tested yet. If something breaks, follow the manual steps below and open an issue.

---

## Manual Setup

### 1. Clone the repo

```bash
git clone https://github.com/kairolang/kairo/
cd kairo
git submodule update --init --recursive # this will take a while since it clones the entire LLVM repo, but it's necessary
cd lib-helix && git checkout main && cd ..
```

### 2. Build the Stage 0 compiler (this branch is for the Stage 1 compiler, which is still in development)

```bash
git checkout archive/beta-helix-0.0.1
xmake
```

### 2.1 Optional: Build the Stage 1 compiler (in development)

```bash
git checkout canary
kbld

# you can also test files that contain `fn Test() -> i32 { ... }` as the entry point, but note that this is not the standard entry point for Kairo programs.
kbld test Toolchain/Lexer/Lexer.kro
```


Output lands in `./build/release/<platform>/bin/`: `kairo` and `kbld`.

### 3. Add the stage0 compiler to PATH (recommended)

**Linux / macOS:**
```bash
export PATH="$PATH:/path/to/kairo/build/release/<platform>/bin"
```
Add that line to your `.bashrc` or `.zshrc` to make it permanent.

**Linux only: optional symlink:**
```bash
sudo ln -s /path/to/kairo/build/release/<platform>/bin/kairo /usr/local/bin/kairo
sudo ln -s /path/to/kairo/build/release/<platform>/bin/kbld  /usr/local/bin/kbld
```

**Windows:**
Add the bin directory (e.g. `C:\...\build\release\windows-x64\bin`) to your system environment PATH.

---

## VSCode Extension (optional but recommended)

Right now VSCode is the only editor with LSP support and syntax highlighting for `.kro` files.

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

**NOTE:** If you open a `.kro` file before configuring the extension, it will annoy you with popups asking for the Kairo path. So ideally, configure the extension first before opening any Kairo files.

### Configure

```bash
python config.py
```

The script will ask for:
- Path to the stage 0 compiler: e.g. `../kairo/build/release/<platform>/bin/kairo`
- Your Python path: e.g. `C:\Python311\python.exe` *(Windows only, usually auto-detected)*
- Path to the LSP server file: e.g. `C:\Users\user\Desktop\kairo-lsp\server\server.py` *(usually auto-detected)*

It'll output something like:

```json
{
    "kairo.path": "C:\\Users\\user\\Desktop\\kairo\\build\\release\\windows-x64\\bin\\kairo.exe",
    "kairo.pythonPath": "C:\\Python311\\python.exe",
    "kairo.serverPath": "C:\\Users\\user\\Desktop\\kairo-lsp\\server\\server.py"
}
```

Copy those values into your VSCode settings: either via the UI (`Ctrl+Shift+P` -> search `kairo`) or directly in `settings.json` (`Ctrl+Shift+P` -> `Preferences: Open Settings (JSON)`).

### Install the extension

Extensions tab (`Ctrl+Shift+X`) -> three dots -> `Install from VSIX...` -> select the `.vsix` file you just built.

Restart VSCode, open a `.kro` file: it should activate automatically.

---

## Debugging

Set breakpoints directly in VSCode and use:
- `Run Kairo File`: runs and attaches the debugger
- `Run Kairo File with Args`: prompts for arguments in comma-separated format (e.g. `arg1,arg2,arg3`)

Both work with `fn main() -> i32 { ... }` or `fn Test() -> i32 { ... }` as your entry point.

> [!WARNING]
> If you're using `fn Test()`, VSCode redirects you to a temporary test file during debugging. Breakpoints still work, but **edits won't be saved back to your original file**: re-running the debugger resets everything. Use `fn main()` for active development.
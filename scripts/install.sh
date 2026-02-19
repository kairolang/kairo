<#
: '
#!/usr/bin/env bash
# ============================================================
#  Kairo Installer — Unix (bash/zsh)
#  Usage: curl -fsSL https://raw.githubusercontent.com/kairolang/kairo-lang/main/install.ps1 | bash
# ============================================================
set -e

KAIRO_REPO="https://github.com/kairolang/kairo-lang"
LSP_REPO="https://github.com/kairolang/kairo-lsp"
KAIRO_BRANCH="beta/helix-0.0.1"
DEFAULT_INSTALL_DIR="$(pwd)/kairo"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
GRAY="\033[0;90m"
BOLD="\033[1m"
RESET="\033[0m"

log()     { echo -e "${CYAN}[kairo]${RESET} $1"; }
ok()      { echo -e "${GREEN}[done]${RESET}  $1"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $1"; }
info()    { echo -e "${GRAY}        $1${RESET}"; }
die()     { echo -e "${RED}[error]${RESET} $1"; exit 1; }
section() { echo -e "\n${BOLD}── $1${RESET}"; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "Required tool not found: '$1'. Please install it and re-run."
}

# ---- detect platform ----
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
    Linux*)
        case "$ARCH" in
            x86_64)  PLATFORM="linux-x64" ;;
            aarch64) PLATFORM="linux-arm64" ;;
            *)        die "Unsupported Linux arch: $ARCH" ;;
        esac
        ;;
    Darwin*)
        case "$ARCH" in
            x86_64)  PLATFORM="macos-x64" ;;
            arm64)   PLATFORM="macos-arm64" ;;
            *)        die "Unsupported macOS arch: $ARCH" ;;
        esac
        ;;
    *)
        die "Unsupported OS: $OS. On Windows, run this script with PowerShell instead."
        ;;
esac

# ---- header ----
echo ""
echo -e "${BOLD}  Kairo Language Installer${RESET}"
echo -e "  Platform detected: ${CYAN}$PLATFORM${RESET}"
echo ""

# ---- check required tools ----
section "Checking dependencies"
for tool in git xmake; do
    log "Checking for '$tool'..."
    need "$tool"
    ok "'$tool' found at $(command -v $tool)"
done

# ---- install dir prompt ----
section "Install location"
info "Everything goes into one directory: repos, build output, and the extension."
info "Default: $DEFAULT_INSTALL_DIR"
info ""
read -r -p "$(echo -e "  Install directory [${CYAN}Enter for default${RESET}]: ")" USER_DIR
INSTALL_DIR="${USER_DIR:-$DEFAULT_INSTALL_DIR}"
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
KAIRO_DIR="$INSTALL_DIR/kairo-lang"
LSP_DIR="$INSTALL_DIR/kairo-lsp"
KAIRO_BIN="$KAIRO_DIR/build/release/$PLATFORM/bin"

echo ""
log "Install directory: $INSTALL_DIR"
info "  kairo-lang source + build  ->  $KAIRO_DIR"
info "  built binaries             ->  $KAIRO_BIN"
info "  kairo-lsp (if selected)    ->  $LSP_DIR"
echo ""
read -r -p "$(echo -e "  Looks good? Continue? [${GREEN}Y${RESET}/n] ")" CONFIRM
[[ "$CONFIRM" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }

# ---- permission check ----
section "Checking permissions"

CAN_SYMLINK=false
SYMLINK_TARGET="/usr/local/bin"

info "To make 'kairo' and 'kbld' available system-wide, we symlink them to $SYMLINK_TARGET."
info "Checking write access..."

if [ -w "$SYMLINK_TARGET" ]; then
    CAN_SYMLINK=true
    ok "Write access to $SYMLINK_TARGET confirmed — no sudo needed."
elif sudo -v 2>/dev/null; then
    CAN_SYMLINK=true
    ok "sudo access confirmed — will use sudo when symlinking binaries."
else
    warn "No write access to $SYMLINK_TARGET and sudo isn't available or was declined."
    warn "Skipping global symlink. After install, add this line to your ~/.bashrc or ~/.zshrc:"
    echo ""
    echo "  export PATH=\"\$PATH:$KAIRO_BIN\""
    echo ""
    read -r -p "  Press Enter to continue without global symlink, or Ctrl+C to abort: "
fi

# ---- create install dir ----
section "Setting up install directory"
if [ -d "$INSTALL_DIR" ]; then
    warn "Directory already exists: $INSTALL_DIR"
    info "Nothing will be deleted. Repos will be fetched/updated in place."
else
    log "Creating $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    ok "Created."
fi

# ---- clone / update kairo-lang ----
section "Fetching kairo-lang"
if [ -d "$KAIRO_DIR/.git" ]; then
    log "Repo already present — fetching latest..."
    info "  git -C $KAIRO_DIR fetch --all"
    git -C "$KAIRO_DIR" fetch --all -q
    ok "Fetch done."
else
    log "Cloning kairo-lang..."
    info "  git clone $KAIRO_REPO $KAIRO_DIR"
    git clone --quiet "$KAIRO_REPO" "$KAIRO_DIR"
    ok "Clone done."
fi

log "Initializing submodules (lib-helix)..."
info "  git submodule update --init --recursive"
git -C "$KAIRO_DIR" submodule update --init --recursive -q
ok "Submodules ready."

log "Checking out build branch: $KAIRO_BRANCH..."
info "  git checkout $KAIRO_BRANCH"
git -C "$KAIRO_DIR" checkout "$KAIRO_BRANCH" -q
info "  git -C lib-helix checkout main"
git -C "$KAIRO_DIR/lib-helix" checkout main -q
ok "On $KAIRO_BRANCH."

# ---- build ----
section "Building stage 0 compiler"
log "Running xmake..."
info "  xmake -y  (in $KAIRO_DIR)"
info "  Compiling ~20k lines of C++ — expect 1–3 minutes depending on your machine."
echo ""
cd "$KAIRO_DIR"
xmake -y
echo ""

if [ ! -f "$KAIRO_BIN/kairo" ]; then
    die "Expected binary not found at $KAIRO_BIN/kairo — build may have failed. Check xmake output above."
fi
ok "Binary verified: $KAIRO_BIN/kairo"

# ---- symlink ----
section "Installing binaries"
if $CAN_SYMLINK; then
    log "Symlinking binaries to $SYMLINK_TARGET..."
    info "  ln -sf $KAIRO_BIN/kairo $SYMLINK_TARGET/kairo"
    info "  ln -sf $KAIRO_BIN/kbld  $SYMLINK_TARGET/kbld"
    if [ -w "$SYMLINK_TARGET" ]; then
        ln -sf "$KAIRO_BIN/kairo" "$SYMLINK_TARGET/kairo"
        ln -sf "$KAIRO_BIN/kbld"  "$SYMLINK_TARGET/kbld"
    else
        sudo ln -sf "$KAIRO_BIN/kairo" "$SYMLINK_TARGET/kairo"
        sudo ln -sf "$KAIRO_BIN/kbld"  "$SYMLINK_TARGET/kbld"
    fi
    ok "'kairo' and 'kbld' are now globally available."
else
    warn "Skipping symlink. Remember to add $KAIRO_BIN to your PATH."
fi

# ---- optional: VSCode extension ----
section "VSCode Extension (optional)"
HAS_CODE=false; HAS_NPM=false
command -v code >/dev/null 2>&1 && HAS_CODE=true
command -v npm  >/dev/null 2>&1 && HAS_NPM=true

if ! $HAS_CODE; then
    warn "'code' CLI not found — skipping. Install VSCode + shell integration and re-run if you want it."
elif ! $HAS_NPM; then
    warn "'npm' not found — skipping. Install Node.js and re-run if you want it."
else
    info "Provides syntax highlighting and LSP support for .kro files in VSCode."
    info "Will clone kairo-lsp to: $LSP_DIR"
    info "Requires npm (build), vsce (auto-installed via npx), python3 (LSP server runtime)."
    echo ""
    read -r -p "$(echo -e "  Install the VSCode extension? [y/${GREEN}N${RESET}] ")" INSTALL_EXT
    if [[ "$INSTALL_EXT" =~ ^[Yy]$ ]]; then

        section "Fetching kairo-lsp"
        if [ -d "$LSP_DIR/.git" ]; then
            log "Repo already present — pulling..."
            git -C "$LSP_DIR" pull -q
            ok "Updated."
        else
            log "Cloning kairo-lsp..."
            info "  git clone $LSP_REPO $LSP_DIR"
            git clone --quiet "$LSP_REPO" "$LSP_DIR"
            ok "Clone done."
        fi

        section "Building extension"
        cd "$LSP_DIR"

        log "Installing npm dependencies..."
        info "  npm install"
        npm install --silent
        ok "npm install done."

        log "Building extension..."
        info "  npm run build --omit=dev"
        npm run build --omit=dev --silent
        ok "Build done."

        log "Packaging as .vsix..."
        info "  npx vsce package --out kairo-language.vsix"
        npx vsce package --out kairo-language.vsix -q
        ok "Packaged: $LSP_DIR/kairo-language.vsix"

        log "Installing extension into VSCode..."
        info "  code --install-extension kairo-language.vsix --force"
        code --install-extension "$LSP_DIR/kairo-language.vsix" --force
        ok "Extension installed."

        PYTHON_PATH="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo 'python3')"
        SERVER_PATH="$LSP_DIR/server/server.py"

        section "VSCode settings required"
        info "Open VSCode settings JSON (Cmd/Ctrl+Shift+P -> 'Preferences: Open Settings JSON')"
        info "and add the following:"
        echo ""
        echo -e "${CYAN}{${RESET}"
        echo -e "  ${GREEN}\"kairo.path\"${RESET}:       ${YELLOW}\"$KAIRO_BIN/kairo\"${RESET},"
        echo -e "  ${GREEN}\"kairo.pythonPath\"${RESET}: ${YELLOW}\"$PYTHON_PATH\"${RESET},"
        echo -e "  ${GREEN}\"kairo.serverPath\"${RESET}: ${YELLOW}\"$SERVER_PATH\"${RESET}"
        echo -e "${CYAN}}${RESET}"
        echo ""
        ok "Open a .kro file in VSCode to verify the extension activates."

    else
        log "Skipping VSCode extension."
    fi
fi

# ---- done ----
section "Done"
echo ""
echo -e "  ${BOLD}Compiler:${RESET}  $KAIRO_BIN/kairo"
echo -e "  ${BOLD}Builder:${RESET}   $KAIRO_BIN/kbld"
if $CAN_SYMLINK; then
echo -e "  ${BOLD}Run:${RESET}       kairo --help"
else
echo -e "  ${BOLD}Add to PATH:${RESET}  export PATH=\"\$PATH:$KAIRO_BIN\""
fi
echo ""
exit 0
'
#>

# ============================================================
#  Kairo Installer — Windows (PowerShell)
#  Usage: iwr https://raw.githubusercontent.com/kairolang/kairo-lang/main/install.ps1 | iex
# ============================================================

$ErrorActionPreference = "Stop"

$KairoRepo   = "https://github.com/kairolang/kairo-lang"
$LspRepo     = "https://github.com/kairolang/kairo-lsp"
$KairoBranch = "beta/helix-0.0.1"
$Platform    = "windows-x64"
$DefaultDir  = "$(Get-Location)\kairo"

function Log     { param($m) Write-Host "[kairo] $m" -ForegroundColor Cyan }
function Ok      { param($m) Write-Host "[done]  $m" -ForegroundColor Green }
function Warn    { param($m) Write-Host "[warn]  $m" -ForegroundColor Yellow }
function Info    { param($m) Write-Host "        $m" -ForegroundColor Gray }
function Die     { param($m) Write-Host "[error] $m" -ForegroundColor Red; exit 1 }
function Section { param($m) Write-Host "`n-- $m" -ForegroundColor White }

function Need {
    param($tool)
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Die "Required tool not found: '$tool'. Please install it and re-run."
    }
}

# ---- header ----
Write-Host ""
Write-Host "  Kairo Language Installer" -ForegroundColor White
Write-Host "  Platform: $Platform" -ForegroundColor Cyan
Write-Host ""

# ---- check deps ----
Section "Checking dependencies"
foreach ($tool in @("git", "xmake")) {
    Log "Checking for '$tool'..."
    Need $tool
    $p = (Get-Command $tool).Source
    Ok "'$tool' found at $p"
}

# ---- install dir prompt ----
Section "Install location"
Info "Everything goes into one directory: repos, build output, and the extension."
Info "Default: $DefaultDir"
Info ""
$UserDir = Read-Host "  Install directory [press Enter for default]"
$InstallDir = if ($UserDir -eq "") { $DefaultDir } else { $UserDir }
$InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir)

$KairoDir  = "$InstallDir\kairo-lang"
$LspDir    = "$InstallDir\kairo-lsp"
$KairoBin  = "$KairoDir\build\release\$Platform\bin"
$KairoExe  = "$KairoBin\kairo.exe"

Write-Host ""
Log "Install directory: $InstallDir"
Info "  kairo-lang source + build  ->  $KairoDir"
Info "  built binaries             ->  $KairoBin"
Info "  kairo-lsp (if selected)    ->  $LspDir"
Write-Host ""
$Confirm = Read-Host "  Looks good? Continue? [Y/n]"
if ($Confirm -match "^[Nn]$") { Write-Host "Aborted."; exit 0 }

# ---- permission check ----
Section "Checking permissions"

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

if ($IsAdmin) {
    Ok "Running as Administrator — will add to system-wide PATH."
} else {
    Warn "Not running as Administrator."
    Info "That's fine — binaries will be added to your user-level PATH instead."
    Info "If you want a system-wide install later, re-run PowerShell as Administrator."
    Write-Host ""
    $Continue = Read-Host "  Continue with user-level PATH? [Y/n]"
    if ($Continue -match "^[Nn]$") { Write-Host "Aborted."; exit 0 }
}

# ---- create install dir ----
Section "Setting up install directory"
if (Test-Path $InstallDir) {
    Warn "Directory already exists: $InstallDir"
    Info "Nothing will be deleted. Repos will be fetched/updated in place."
} else {
    Log "Creating $InstallDir..."
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Ok "Created."
}

# ---- clone / update kairo-lang ----
Section "Fetching kairo-lang"
if (Test-Path "$KairoDir\.git") {
    Log "Repo already present — fetching latest..."
    Info "  git -C $KairoDir fetch --all"
    git -C $KairoDir fetch --all -q
    Ok "Fetch done."
} else {
    Log "Cloning kairo-lang..."
    Info "  git clone $KairoRepo $KairoDir"
    git clone --quiet $KairoRepo $KairoDir
    Ok "Clone done."
}

Log "Initializing submodules (lib-helix)..."
Info "  git submodule update --init --recursive"
git -C $KairoDir submodule update --init --recursive -q
Ok "Submodules ready."

Log "Checking out build branch: $KairoBranch..."
Info "  git checkout $KairoBranch"
git -C $KairoDir checkout $KairoBranch -q
Set-Location "$KairoDir\lib-helix"
Info "  git checkout main  (lib-helix)"
git checkout main -q
Set-Location $KairoDir
Ok "On $KairoBranch."

# ---- build ----
Section "Building stage 0 compiler"
Log "Running xmake..."
Info "  xmake -y  (in $KairoDir)"
Info "  Compiling ~20k lines of C++ -- expect 1-3 minutes depending on your machine."
Write-Host ""
Set-Location $KairoDir
xmake -y
Write-Host ""

if (-not (Test-Path $KairoExe)) {
    Die "Expected binary not found at $KairoExe -- build may have failed. Check xmake output above."
}
Ok "Binary verified: $KairoExe"

# ---- PATH ----
Section "Installing binaries"
$Scope = if ($IsAdmin) { "Machine" } else { "User" }
$CurrentPath = [Environment]::GetEnvironmentVariable("PATH", $Scope)
if ($CurrentPath -notlike "*$KairoBin*") {
    Log "Adding $KairoBin to $Scope PATH..."
    Info "  [Environment]::SetEnvironmentVariable('PATH', ..., '$Scope')"
    [Environment]::SetEnvironmentVariable("PATH", "$CurrentPath;$KairoBin", $Scope)
    $env:PATH = "$env:PATH;$KairoBin"
    Ok "PATH updated. Restart your terminal for it to take effect."
} else {
    Ok "$KairoBin is already in PATH."
}

# ---- optional: VSCode extension ----
Section "VSCode Extension (optional)"
$HasCode = Get-Command code -ErrorAction SilentlyContinue
$HasNpm  = Get-Command npm  -ErrorAction SilentlyContinue

if (-not $HasCode) {
    Warn "'code' CLI not found -- skipping. Install VSCode with shell integration and re-run if you want it."
} elseif (-not $HasNpm) {
    Warn "'npm' not found -- skipping. Install Node.js and re-run if you want it."
} else {
    Info "Provides syntax highlighting and LSP support for .kro files in VSCode."
    Info "Will clone kairo-lsp to: $LspDir"
    Info "Requires npm (build), vsce (auto-installed via npx), python (LSP server runtime)."
    Write-Host ""
    $InstallExt = Read-Host "  Install the VSCode extension? [y/N]"
    if ($InstallExt -match "^[Yy]$") {

        Section "Fetching kairo-lsp"
        if (Test-Path "$LspDir\.git") {
            Log "Repo already present -- pulling..."
            git -C $LspDir pull -q
            Ok "Updated."
        } else {
            Log "Cloning kairo-lsp..."
            Info "  git clone $LspRepo $LspDir"
            git clone --quiet $LspRepo $LspDir
            Ok "Clone done."
        }

        Section "Building extension"
        Set-Location $LspDir

        Log "Installing npm dependencies..."
        Info "  npm install"
        npm install --silent
        Ok "npm install done."

        Log "Building extension..."
        Info "  npm run build --omit=dev"
        npm run build --omit=dev --silent
        Ok "Build done."

        Log "Packaging as .vsix..."
        Info "  npx vsce package --out kairo-language.vsix"
        npx vsce package --out kairo-language.vsix -q
        Ok "Packaged: $LspDir\kairo-language.vsix"

        Log "Installing extension into VSCode..."
        Info "  code --install-extension kairo-language.vsix --force"
        code --install-extension "$LspDir\kairo-language.vsix" --force
        Ok "Extension installed."

        $PyPath     = (Get-Command python -ErrorAction SilentlyContinue)?.Source ?? "python"
        $ServerPath = "$LspDir\server\server.py"

        Section "VSCode settings required"
        Info "Open VSCode settings JSON (Ctrl+Shift+P -> 'Preferences: Open Settings JSON')"
        Info "and add the following:"
        Write-Host ""
        Write-Host @"
{
  "kairo.path":       "$KairoExe",
  "kairo.pythonPath": "$PyPath",
  "kairo.serverPath": "$ServerPath"
}
"@ -ForegroundColor Yellow
        Write-Host ""
        Ok "Open a .kro file in VSCode to verify the extension activates."

    } else {
        Log "Skipping VSCode extension."
    }
}

# ---- done ----
Section "Done"
Write-Host ""
Write-Host "  Compiler:  $KairoExe" -ForegroundColor White
Write-Host "  Builder:   $KairoBin\kbld.exe" -ForegroundColor White
Write-Host "  Run:       kairo --help  (restart terminal first)" -ForegroundColor White
Write-Host ""
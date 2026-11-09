#!/bin/sh
set "x\" <# "
# Kairo release installer: ONE file that runs under POSIX sh (Linux, macOS, FreeBSD, NetBSD)
# and under PowerShell (Windows PowerShell 5.1, pwsh 7).
#
#   Linux / macOS / BSD (any shell, fish included):  curl -fsSL https://kairolang.org/install.sh | sh
#   Windows PowerShell:                              irm https://kairolang.org/install.ps1 | iex
#
# How the polyglot works: line 2 is a harmless `set` to sh (the <# is inside its double quotes),
# but PowerShell reads "x\" as a complete string and then sees the <# block-comment opener, so
# treats everything up to the matching close marker (the line that ends this block, below the
# sh half) as a block comment. sh runs `main` and exits before it ever reaches the PowerShell
# half. So: never write the PowerShell block-comment close marker anywhere in the sh half, and
# keep the whole file ASCII with LF line endings (Windows PowerShell 5.1 reads BOM-less files
# as ANSI).
#
# Both halves download kairo-<ver>-<triple>.{tar.xz,zip} and SHA256SUMS, verify the archive
# BEFORE unpacking, never need root, and install per user:
#
#   KAIRO_VERSION    version to install            (default: 0.2.0)
#   KAIRO_PREFIX     sh: install prefix            (default: $HOME/.local; tree in
#                       $KAIRO_PREFIX/share/kairo/<ver>, tools linked into $KAIRO_PREFIX/bin)
#                    PowerShell: install root      (default: %LOCALAPPDATA%\Kairo; tree in
#                       <root>\<ver>, <root>\<ver>\bin added to the user Path)
#   KAIRO_BASE_URL   where archive + SHA256SUMS live
#                    (default: https://github.com/kairolang/kairo/releases/download/v<version>;
#                     a file:// URL works, for testing a local dist/ directory)
#   KAIRO_TRIPLE     override the detected target (e.g. armv7-windows-gnu, or a musl build
#                    on a glibc host)

VERSION_DEFAULT=0.2.0
BUILD_CMD='python3 build.py --release kairo kcc kld kfmt'

say() { printf 'kairo-install: %s\n' "$*"; }
die() { printf 'kairo-install: error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

detect_triple() {
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Linux)
            case "$arch" in
                x86_64|amd64) echo x86_64-linux-musl ;;
                aarch64|arm64) echo aarch64-linux-musl ;;
                i686|i786) echo i686-linux-musl ;;
                i386|i486|i586) die "unsupported CPU $arch: the i686 build needs a Pentium 4 class CPU or newer" ;;
                armv7*|armv8l) echo armv7-linux-musl ;;
                armv6*|armv5*|armv4*) die "unsupported CPU $arch: the ARM build needs ARMv7 or newer (this is ARMv6 or older)" ;;
                riscv64) echo riscv64-linux-musl ;;
                *) die "unsupported Linux architecture: $arch" ;;
            esac ;;
        Darwin)
            # Rosetta: an x86_64 shell on Apple Silicon still wants the native arm64 build.
            if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
                echo arm64-apple-macosx11.0
                return
            fi
            case "$arch" in
                arm64) echo arm64-apple-macosx11.0 ;;
                x86_64) echo x86_64-apple-macosx10.15 ;;
                *) die "unsupported macOS architecture: $arch" ;;
            esac ;;
        FreeBSD)
            case "$arch" in
                amd64|x86_64) echo x86_64-unknown-freebsd ;;
                arm64|aarch64) echo aarch64-unknown-freebsd ;;
                *) die "unsupported FreeBSD architecture: $arch" ;;
            esac ;;
        NetBSD)
            case "$arch" in
                amd64|x86_64) echo x86_64-unknown-netbsd ;;
                evbarm|aarch64|arm64) echo aarch64-unknown-netbsd ;;
                *) die "unsupported NetBSD architecture: $arch" ;;
            esac ;;
        MINGW*|MSYS*|CYGWIN*)
            die "this is a POSIX shell on Windows; run the installer from PowerShell instead:  irm https://kairolang.org/install.ps1 | iex" ;;
        *) die "unsupported OS: $os (build from source: $BUILD_CMD)" ;;
    esac
}

fetch() { # url dest
    case "$1" in
        file://*) cp "${1#file://}" "$2" ;;
        *) if have curl; then curl -fsSL "$1" -o "$2"
           elif have wget; then wget -q "$1" -O "$2"
           elif have fetch; then fetch -q -o "$2" "$1"      # FreeBSD base system
           elif have ftp; then ftp -o "$2" "$1"             # NetBSD base system
           else die "need curl, wget, fetch or ftp to download"; fi ;;
    esac
}

sha256_of() {
    if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
    elif have shasum; then shasum -a 256 "$1" | cut -d' ' -f1
    elif have sha256; then sha256 "$1" | awk '{print $NF}'      # FreeBSD/NetBSD: "SHA256 (f) = hash"
    elif have openssl; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else die "need sha256sum, shasum, sha256 or openssl to verify the download"; fi
}

main() {
    VERSION="${KAIRO_VERSION:-$VERSION_DEFAULT}"
    PREFIX="${KAIRO_PREFIX:-$HOME/.local}"
    BASE="${KAIRO_BASE_URL:-https://github.com/kairolang/kairo/releases/download/v$VERSION}"

    # An assignment from $(...) keeps the substitution's status, so a die inside detect_triple stops us.
    TRIPLE="${KAIRO_TRIPLE:-}"
    [ -n "$TRIPLE" ] || TRIPLE=$(detect_triple) || exit 1
    case "$TRIPLE" in
        *apple-macosx*|*windows*) EXT=zip ;;
        *) EXT=tar.xz ;;
    esac
    NAME="kairo-$VERSION-$TRIPLE"
    ARCHIVE="$NAME.$EXT"

    TMP=$(mktemp -d "${TMPDIR:-/tmp}/kairo-install.XXXXXX") || die "could not create a temp directory"
    STAGE=
    trap 'rm -rf "$TMP" ${STAGE:+"$STAGE"}' EXIT INT TERM

    say "installing Kairo $VERSION for $TRIPLE"
    fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS" || die "could not download $BASE/SHA256SUMS"
    want=$(awk -v f="$ARCHIVE" '$2 == f { print $1 }' "$TMP/SHA256SUMS")
    if [ -z "$want" ]; then
        avail=$(sed -n -e "s/^[0-9a-fA-F]*  kairo-$VERSION-\\(.*\\)\\.tar\\.xz\$/\\1/p" \
                       -e "s/^[0-9a-fA-F]*  kairo-$VERSION-\\(.*\\)\\.zip\$/\\1/p" "$TMP/SHA256SUMS" | tr '\n' ' ')
        die "no archive for $TRIPLE in this release ($ARCHIVE is not listed in SHA256SUMS).
  available: ${avail:-none}
  to build it yourself:  $BUILD_CMD
  (KAIRO_TRIPLE=<triple> overrides detection)"
    fi
    say "downloading $ARCHIVE"
    fetch "$BASE/$ARCHIVE" "$TMP/$ARCHIVE" || die "could not download $BASE/$ARCHIVE"
    got=$(sha256_of "$TMP/$ARCHIVE")
    [ "$got" = "$want" ] || die "checksum mismatch for $ARCHIVE (expected $want, got $got); nothing was installed"
    say "checksum ok"

    DEST="$PREFIX/share/kairo/$VERSION"
    BIN="$PREFIX/bin"
    # Unpack beside the destination first so a failed unpack never leaves a half install.
    mkdir -p "$PREFIX/share/kairo" "$BIN"
    STAGE="$PREFIX/share/kairo/.install-$VERSION.$$"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    if [ "$EXT" = zip ]; then
        have unzip || die "need unzip to unpack $ARCHIVE"
        unzip -q "$TMP/$ARCHIVE" -d "$STAGE" || die "could not unpack $ARCHIVE"
        # Release binaries are not notarized; clear Gatekeeper's quarantine flag.
        if have xattr; then xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true; fi
    else
        have xz || die "need xz to unpack $ARCHIVE"
        tar -xJf "$TMP/$ARCHIVE" -C "$STAGE" || die "could not unpack $ARCHIVE"
    fi
    [ -d "$STAGE/$NAME" ] || die "$ARCHIVE does not contain the expected top directory $NAME/"
    rm -rf "$DEST"
    mv "$STAGE/$NAME" "$DEST"

    for f in "$DEST"/bin/*; do
        ln -sf "$f" "$BIN/$(basename "$f")"
    done
    say "installed to $DEST"
    say "linked $(ls "$DEST/bin" | wc -l | tr -d ' ') tools into $BIN"
    case ":$PATH:" in
        *":$BIN:"*) ;;
        *) say "add $BIN to your PATH:"
           say "  sh/bash/zsh:  export PATH=\"$BIN:\$PATH\""
           say "  fish:         fish_add_path $BIN" ;;
    esac
    "$BIN/kairo" --version 2>/dev/null || true
}

main
exit $?
# Never reached; this heredoc only hides the PowerShell half from sh -n / shellcheck (its
# terminator is the lone # on the file's last line, a harmless PowerShell comment).
: <<\#

#>
# ---------------------------------------------------------------------------------------
# PowerShell half (Windows PowerShell 5.1 and pwsh 7). Everything above is a comment here.
# ---------------------------------------------------------------------------------------
function Get-Remote([string]$Url, [string]$Dest) {
    # file:// is for testing a local dist/ directory; Invoke-WebRequest only does it on 5.1.
    if ($Url -like 'file://*') { Copy-Item -LiteralPath ([Uri]$Url).LocalPath -Destination $Dest -Force }
    else { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Dest }
}

function Install-Kairo {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes 5.1 downloads ~10x slower
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    $ver = if ($env:KAIRO_VERSION) { $env:KAIRO_VERSION } else { '0.2.0' }
    $buildCmd = 'python3 build.py --release kairo kcc kld kfmt'
    # $IsWindows only exists in pwsh 6+; Windows PowerShell 5.1 is Windows by definition.
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or [bool]$IsWindows
    $testWin = ($env:KAIRO_TEST_FORCE_WINDOWS -eq '1')   # test hook, deliberately undocumented

    if ((-not $onWindows) -and (-not $testWin)) {
        # pwsh on Linux/macOS/BSD: this is the sh installer's job; never install a Windows build here.
        $sh = Get-Command sh -ErrorAction SilentlyContinue
        if (-not $sh) { throw 'this is not Windows and no sh was found; run the installer with: curl -fsSL https://kairolang.org/install.sh | sh' }
        $self = $PSCommandPath
        $tmp = $null
        if (-not ($self -and (Test-Path -LiteralPath $self))) {
            $url = if ($env:KAIRO_INSTALL_SH_URL) { $env:KAIRO_INSTALL_SH_URL } else { 'https://kairolang.org/install.sh' }
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kairo-install-" + [Guid]::NewGuid().ToString('N') + '.sh')
            Get-Remote $url $tmp
            $self = $tmp
        }
        Write-Host 'kairo-install: not Windows; handing off to the sh installer'
        try { & $sh.Source $self } finally { if ($tmp) { Remove-Item -Force -ErrorAction SilentlyContinue $tmp } }
        if ($LASTEXITCODE -ne 0) { throw "the sh installer failed (exit $LASTEXITCODE)" }
        return
    }

    $triple = $env:KAIRO_TRIPLE
    if (-not $triple) {
        $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
        if (-not $arch) { try { $arch = [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { } }
        switch -Regex ($arch) {
            '^(AMD64|X64)$'   { $triple = 'x86_64-windows-gnu'; break }
            '^ARM64$'         { $triple = 'aarch64-windows-gnu'; break }
            '^(x86|X86)$'     { $triple = 'i686-windows-gnu'; break }
            '^ARM$'           { $triple = 'armv7-windows-gnu'; break }
            default           { throw "unsupported Windows architecture: '$arch' (set KAIRO_TRIPLE to override)" }
        }
    }
    $ext = if ($triple -match 'windows|apple-macosx') { 'zip' } else { 'tar.xz' }
    if ($ext -ne 'zip') { throw "$triple is a .tar.xz build, which PowerShell cannot unpack; use the sh installer for it" }
    $name = "kairo-$ver-$triple"
    $archive = "$name.$ext"
    $base = if ($env:KAIRO_BASE_URL) { $env:KAIRO_BASE_URL.TrimEnd('/') } else { "https://github.com/kairolang/kairo/releases/download/v$ver" }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kairo-install-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $stage = $null
    try {
        Write-Host "kairo-install: installing Kairo $ver for $triple"
        try { Get-Remote "$base/SHA256SUMS" (Join-Path $tmp 'SHA256SUMS') } catch { throw "could not download $base/SHA256SUMS : $($_.Exception.Message)" }
        $want = $null
        $avail = @()
        foreach ($line in (Get-Content -LiteralPath (Join-Path $tmp 'SHA256SUMS'))) {
            if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
                if ($Matches[2] -eq $archive) { $want = $Matches[1] }
                if ($Matches[2] -match "^kairo-$([regex]::Escape($ver))-(.+)\.(tar\.xz|zip)$") { $avail += $Matches[1] }
            }
        }
        if (-not $want) {
            $list = if ($avail.Count) { $avail -join ' ' } else { 'none' }
            throw "no archive for $triple in this release ($archive is not listed in SHA256SUMS).`n  available: $list`n  to build it yourself:  $buildCmd`n  (set KAIRO_TRIPLE=<triple> to override detection)"
        }
        Write-Host "kairo-install: downloading $archive"
        $zip = Join-Path $tmp $archive
        try { Get-Remote "$base/$archive" $zip } catch { throw "could not download $base/$archive : $($_.Exception.Message)" }
        $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash
        if ($got -ne $want) { throw "checksum mismatch for $archive (expected $want, got $got); nothing was installed" }
        Write-Host 'kairo-install: checksum ok'

        $root = if ($env:KAIRO_PREFIX) { $env:KAIRO_PREFIX } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Kairo' } else { Join-Path $HOME 'AppData\Local\Kairo' }
        $dest = Join-Path $root $ver
        # Unpack beside the destination first so a failed unpack never leaves a half install.
        $stage = Join-Path $root (".install-$ver-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
        $top = Join-Path $stage $name
        if (-not (Test-Path -LiteralPath $top)) { throw "$archive does not contain the expected top directory $name\" }
        if (Test-Path -LiteralPath $dest) { Remove-Item -Recurse -Force -LiteralPath $dest }
        Move-Item -LiteralPath $top -Destination $dest
        $bin = Join-Path $dest 'bin'
        Write-Host "kairo-install: installed to $dest"

        $norm = { param($p) $p.TrimEnd('\', '/') }
        if ($testWin) {
            Write-Host 'kairo-install: (test mode) skipped the user Path write'
        } else {
            $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
            $parts = @(); if ($cur) { $parts = @($cur -split ';' | Where-Object { $_ }) }
            # Drop bin dirs of earlier installs under the same root so Path does not accumulate them.
            $rootN = & $norm $root
            $parts = @($parts | Where-Object { ($_ -notlike "$rootN\*\bin") -or ((& $norm $_) -ieq (& $norm $bin)) })
            if (-not ($parts | Where-Object { (& $norm $_) -ieq (& $norm $bin) })) { $parts += $bin }
            [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
        }
        if (-not (($env:Path -split ';') | Where-Object { $_ -and ((& $norm $_) -ieq (& $norm $bin)) })) { $env:Path = "$bin;$env:Path" }
        Write-Host "kairo-install: $bin is on your user Path (new terminals pick it up; this session already has it)"
        $exe = Join-Path $bin 'kairo.exe'
        if ($onWindows -and (Test-Path -LiteralPath $exe)) { try { & $exe --version } catch { } }
    } finally {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
        if ($stage) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage }
    }
}

try {
    Install-Kairo
} catch {
    [Console]::Error.WriteLine("kairo-install: error: $($_.Exception.Message)")
    # `irm | iex` runs in the caller's session, where `exit` would close the terminal.
    if ($PSCommandPath) { exit 1 }
}
#

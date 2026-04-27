#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ROOT      = if ($env:KBLD_ROOT)      { $env:KBLD_ROOT }      else { Split-Path $PSScriptRoot -Parent }
$BUILD_DIR = if ($env:KBLD_BUILD_DIR) { $env:KBLD_BUILD_DIR } else { Join-Path $ROOT "build" }
$TRIPLE    = if ($env:KBLD_TRIPLE)    { $env:KBLD_TRIPLE }    else { "x86_64-windows-msvc" }
$MODE      = if ($env:KBLD_MODE)      { $env:KBLD_MODE }      else { "release" }
$JOBS      = if ($env:LINK_JOBS)      { $env:LINK_JOBS }      else { $env:NUMBER_OF_PROCESSORS }

$LLVM_SRC    = Join-Path $ROOT "Lib\llvm-runtimes"
$LLVM_BUILD  = Join-Path $BUILD_DIR "llvm"
$LLVM_MARKER = Join-Path $LLVM_BUILD "bin\LLVM.dll"
$OUT_LIB     = Join-Path $BUILD_DIR "$TRIPLE\$MODE\lib"
$TARGETS     = if ($env:LLVM_TARGETS) { $env:LLVM_TARGETS } else { "X86;AArch64;WebAssembly" }

Write-Host "[llvm] root:      $ROOT"
Write-Host "[llvm] triple:    $TRIPLE"
Write-Host "[llvm] mode:      $MODE"
Write-Host "[llvm] out_lib:   $OUT_LIB"
Write-Host "[llvm] jobs:      $JOBS"
Write-Host "[llvm] targets:   $TARGETS"

# ── check submodule ────────────────────────────────────────────────────────────
if (-not (Test-Path (Join-Path $LLVM_SRC "llvm\CMakeLists.txt"))) {
    Write-Error "[llvm] error: Lib/llvm-runtimes submodule not initialised`nrun: git submodule update --init --recursive Lib/llvm-runtimes"
    exit 1
}

# ── copy helper ────────────────────────────────────────────────────────────────
function Copy-Libs {
    param([string]$Src)
    New-Item -ItemType Directory -Force -Path $OUT_LIB | Out-Null
    $bin = Join-Path (Split-Path $Src -Parent) "bin"
    # DLLs land in bin/, import libs in lib/
    foreach ($pattern in @("LLVM*.dll","clang*.dll","lld*.dll")) {
        Get-ChildItem -Path $bin -Filter $pattern -ErrorAction SilentlyContinue |
            Copy-Item -Destination $OUT_LIB -Force
    }
    foreach ($pattern in @("LLVM*.lib","clang*.lib","lld*.lib")) {
        Get-ChildItem -Path $Src -Filter $pattern -ErrorAction SilentlyContinue |
            Copy-Item -Destination $OUT_LIB -Force
    }
    Write-Host "[llvm] libs copied to $OUT_LIB"
}

# ── skip if already built ──────────────────────────────────────────────────────
if (Test-Path $LLVM_MARKER) {
    Write-Host "[llvm] submodule build exists, skipping rebuild."
    Copy-Libs (Join-Path $LLVM_BUILD "lib")
    exit 0
}

# ── locate VsDevCmd.bat ───────────────────────────────────────────────────────
# mirrors find_clang_cl_windows() logic from your C++ code
function Find-VsDevCmd {
    # 1. check if we're already in a dev prompt
    if ($env:VSINSTALLDIR) {
        $candidate = Join-Path $env:VSINSTALLDIR "Common7\Tools\VsDevCmd.bat"
        if (Test-Path $candidate) { return $candidate }
    }

    # 2. vswhere
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
        if ($vsPath) {
            $candidate = Join-Path $vsPath "Common7\Tools\VsDevCmd.bat"
            if (Test-Path $candidate) { return $candidate }
        }
    }

    # 3. hardcoded fallback paths (mirrors your C++ fallback_vs logic)
    $fallbacks = @(
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat"
    )
    foreach ($f in $fallbacks) {
        if (Test-Path $f) { return $f }
    }
    return $null
}

$vsDevCmd = Find-VsDevCmd
if (-not $vsDevCmd) {
    Write-Error "[llvm] error: could not locate VsDevCmd.bat`nInstall Visual Studio with 'Desktop development with C++' workload"
    exit 1
}
Write-Host "[llvm] using VS env: $vsDevCmd"

# ── verify ninja is available ─────────────────────────────────────────────────
if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) {
    Write-Error "[llvm] error: ninja not foundinstall via 'winget install Ninja-build.Ninja' or add to PATH"
    exit 1
}

# ── build cmake args string ───────────────────────────────────────────────────
# We invoke VsDevCmd.bat then cmake in a single cmd.exe shell so the MSVC
# environment variables (INCLUDE, LIB, PATH additions) are all live when
# cmake runs. This mirrors running from the Developer Command Prompt.
$cmakeArgs = @(
    "-S `"$LLVM_SRC\llvm`""
    "-B `"$LLVM_BUILD`""
    "-G Ninja"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_C_COMPILER=clang"
    "-DCMAKE_CXX_COMPILER=clang++"
    "-DCMAKE_LINKER=lld-link"
    "-DLLVM_ENABLE_PROJECTS=clang;lld;clang-tools-extra"
    "-DLLVM_TARGETS_TO_BUILD=`"$TARGETS`""
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    "-DLLVM_ENABLE_RTTI=ON"
    "-DLLVM_ENABLE_EH=ON"
    "-DLLVM_USE_CRT_RELEASE=MD"
    "-DLLVM_INCLUDE_TESTS=OFF"
    "-DLLVM_INCLUDE_EXAMPLES=OFF"
    "-DLLVM_INCLUDE_BENCHMARKS=OFF"
    "-DLLVM_BUILD_TOOLS=OFF"
    "-DLLVM_ENABLE_BINDINGS=OFF"
    "-DLLVM_ENABLE_ZLIB=OFF"
    "-DLLVM_ENABLE_ZSTD=OFF"
    "-DLLVM_ENABLE_LIBXML2=OFF"
    "-DLLVM_ENABLE_LTO=ON"
    "-DLLVM_PARALLEL_LINK_JOBS=$JOBS"
) -join " "

$ninjaCmd = "ninja -C `"$LLVM_BUILD`" -j$JOBS"
$batchCmd = "call `"$vsDevCmd`" -arch=x64 -host_arch=x64 && cmake $cmakeArgs && $ninjaCmd"

Write-Host "[llvm] configuring and building..."
Write-Host "[llvm] cmd: $batchCmd"

$proc = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c", $batchCmd `
    -NoNewWindow -Wait -PassThru

if ($proc.ExitCode -ne 0) {
    Write-Error "[llvm] build failed with exit code $($proc.ExitCode)"
    exit $proc.ExitCode
}

Copy-Libs (Join-Path $LLVM_BUILD "lib")
Write-Host "[llvm] done."
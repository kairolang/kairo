#Requires -Version 5.1
# TOOLCHAIN LINKAGE INVARIANT - do not violate:
#   Linux/macOS : shared (libLLVM.so/.dylib), one copy in lib/, thin bins
#   Windows     : static (.lib), forced - libLLVM.dll is unsupported on Windows
#   No system-LLVM fallback on any platform (patched fork required).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ROOT      = if ($env:KBLD_ROOT)      { $env:KBLD_ROOT }      else { Split-Path $PSScriptRoot -Parent }
$BUILD_DIR = if ($env:KBLD_BUILD_DIR) { $env:KBLD_BUILD_DIR } else { Join-Path $ROOT "build" }
$TRIPLE    = "x86_64-pc-windows-msvc"
$MODE      = if ($env:KBLD_MODE)      { $env:KBLD_MODE }      else { "release" }
$JOBS      = $env:NUMBER_OF_PROCESSORS
$LINK_JOBS = $env:NUMBER_OF_PROCESSORS

$LLVM_SRC    = Join-Path $ROOT "Lib\llvm-runtimes"
$LLVM_BUILD  = Join-Path $BUILD_DIR "llvm"
$LLVM_MARKER = Join-Path $LLVM_BUILD "lib\LLVMCore.lib"
$OUT_LIB     = Join-Path $BUILD_DIR "$TRIPLE\$MODE\lib"
$TARGETS     = "X86;AArch64;ARM;RISCV;WebAssembly"

Write-Host "[llvm] root:      $ROOT"
Write-Host "[llvm] triple:    $TRIPLE"
Write-Host "[llvm] mode:      $MODE"
Write-Host "[llvm] out_lib:   $OUT_LIB"
Write-Host "[llvm] jobs:      $JOBS"
Write-Host "[llvm] targets:   $TARGETS"

# verify submodule is actually checked out
if (-not (Test-Path (Join-Path $LLVM_SRC "llvm\CMakeLists.txt"))) {
    Write-Error ("[llvm] error: Lib/llvm-runtimes is not checked out.`n" +
                 "[llvm] this is our PATCHED llvm-project fork (custom Clang PP-token`n" +
                 "[llvm] injection). it is REQUIRED - there is no system-LLVM fallback.`n" +
                 "[llvm] run: git submodule update --init --recursive Lib/llvm-runtimes")
    exit 1
}

# copy helper
function Copy-Libs {
    param([string]$Src)
    New-Item -ItemType Directory -Force -Path $OUT_LIB | Out-Null
    $bin = Join-Path (Split-Path $Src -Parent) "bin"
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

# skip if already built
if (Test-Path $LLVM_MARKER) {
    Write-Host "[llvm] patched llvm already built, skipping rebuild."
    Copy-Libs (Join-Path $LLVM_BUILD "lib")
    exit 0
}

# why we always build from source
Write-Host ""
Write-Host "[llvm] ============================================================"
Write-Host "[llvm]  BUILDING PATCHED LLVM FROM SOURCE"
Write-Host "[llvm] ------------------------------------------------------------"
Write-Host "[llvm]  Kairo links our llvm-project fork, which carries a custom"
Write-Host "[llvm]  Clang patch (preprocessor token injection) that the Kairo"
Write-Host "[llvm]  frontend depends on. System LLVM does NOT have this patch"
Write-Host "[llvm]  and would produce a silently broken compiler, so there is"
Write-Host "[llvm]  no system fallback path. This is a one-time build."
Write-Host "[llvm]  Expect 30-90 min. Output streams below (and to build log)."
Write-Host "[llvm] ============================================================"
Write-Host ""

# locate VsDevCmd.bat
function Find-VsDevCmd {
    if ($env:VSINSTALLDIR) {
        $candidate = Join-Path $env:VSINSTALLDIR "Common7\Tools\VsDevCmd.bat"
        if (Test-Path $candidate) { return $candidate }
    }
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

if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) {
    Write-Error "[llvm] error: ninja not found`ninstall via 'winget install Ninja-build.Ninja' or add to PATH"
    exit 1
}

# build cmake args string
$cmakeArgs = @(
    "-S `"$LLVM_SRC\llvm`""
    "-B `"$LLVM_BUILD`""
    "-G Ninja"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_C_COMPILER=clang"
    "-DCMAKE_CXX_COMPILER=clang++"
    "-DCMAKE_LINKER=lld-link"
    "-DLLVM_ENABLE_PROJECTS=`"clang;lld`""
    "-DLLVM_TARGETS_TO_BUILD=`"$TARGETS`""
    "-DLLVM_ENABLE_RTTI=ON"
    "-DLLVM_ENABLE_EH=ON"
    "-DLLVM_INCLUDE_TESTS=OFF"
    "-DLLVM_INCLUDE_EXAMPLES=OFF"
    "-DLLVM_INCLUDE_BENCHMARKS=OFF"
    "-DLLVM_USE_CRT_RELEASE=MD"
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"
    "-DLLVM_BUILD_TOOLS=OFF"
    "-DLLVM_OPTIMIZED_TABLEGEN=ON"
    "-DCLANG_BUILD_TOOLS=OFF"
    "-DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF"
    "-DLLVM_ENABLE_BINDINGS=OFF"
    "-DLLVM_ENABLE_ZLIB=FORCE_ON"
    "-DLLVM_ENABLE_ZSTD=FORCE_ON"
    "-DLLVM_ENABLE_LIBXML2=OFF"
    "-DLLVM_ENABLE_LTO=Thin"
    "-DLLVM_PARALLEL_LINK_JOBS=$JOBS"
) -join " "

$ninjaCmd = "ninja -C `"$LLVM_BUILD`" -j$JOBS"
$logFile  = Join-Path $BUILD_DIR "llvm-build.log"
$batchCmd = "call `"$vsDevCmd`" -arch=x64 -host_arch=x64 && cmake $cmakeArgs && $ninjaCmd"

Write-Host "[llvm] configuring and building (streaming, tee to $logFile)..."

# Stream to console AND log. The old version redirected both streams to files,
# leaving the user staring at nothing for the whole build. cmd /c ... 2>&1 | Tee
# keeps it live.
New-Item -ItemType Directory -Force -Path $BUILD_DIR | Out-Null
& cmd.exe /c "$batchCmd 2>&1" | Tee-Object -FilePath $logFile
$code = $LASTEXITCODE

if ($code -ne 0) {
    Write-Error "[llvm] build failed with exit code $code (see $logFile)"
    exit $code
}

Copy-Libs (Join-Path $LLVM_BUILD "lib")
Write-Host "[llvm] done."
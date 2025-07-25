<#
.SYNOPSIS
    builds the project on windows with cmake and visual studio 17 2022.
.DESCRIPTION
    creates build directories, runs cmake with optional debug/release and llvm-config flags,
    copies folders from lib-helix, and removes files from the build directory. uses vswhere
    to find the visual studio developer command prompt if mingw, cmake, or ninja is missing.
.PARAMETER BuildType
    specifies the build type: -debug or -release (default: Release).
.PARAMETER LlvmConfig
    path to llvm-config executable (optional).
.PARAMETER Clean
    if specified, cleans the build directory before building. (-Clean)
#>

param (
    [ValidateSet("Debug", "Release")]
    [string]$BuildType = "Release",
    [string]$LlvmConfig = "",
    [switch]$Clean = $false
)

# set target triple
$TRIPLE = "x86_64-windows-msvc"

# check for mingw, cmake, and ninja
$UseVsDev = $false
if (-not (Get-Command "g++" -ErrorAction SilentlyContinue) -or
    -not (Get-Command "cmake" -ErrorAction SilentlyContinue) -or
    -not (Get-Command "ninja" -ErrorAction SilentlyContinue)) {
    Write-Host "MinGW, CMake, or Ninja not found. Attempting to use Visual Studio Developer Command Prompt."
    $UseVsDev = $true
}

# find visual studio developer command prompt using vswhere
if ($UseVsDev) {
    $VsWherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $VsWherePath)) {
        Write-Error "vswhere.exe not found at $VsWherePath. Please ensure Visual Studio is installed."
        exit 1
    }
    $VsPath = & $VsWherePath -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $VsPath) {
        Write-Error "Visual Studio installation not found."
        exit 1
    }
    $VsDevCmd = Join-Path $VsPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $VsDevCmd)) {
        Write-Error "VsDevCmd.bat not found at $VsDevCmd."
        exit 1
    }
}

# clean build directory if requested
if ($Clean) {
    if (Test-Path "build\$TRIPLE") {
        Remove-Item -Recurse -Force -Path "build\$TRIPLE"
    }
}

# create build directories
New-Item -Path "build" -ItemType Directory -Force | Out-Null
New-Item -Path "build\$TRIPLE" -ItemType Directory -Force | Out-Null

# get number of threads for parallel build
$NumThreads = [Environment]::ProcessorCount
if ($NumThreads -gt 3) {
    $NumThreads = $NumThreads - 2
}

# prepare cmake arguments
$CMAKE_ARGS = @(
    "-G", "Visual Studio 17 2022",
    "-A", "x64",
    "-DCMAKE_BUILD_TYPE=$BuildType",
    "-DCMAKE_BUILD_PARALLEL_LEVEL=$NumThreads",
    "..\.."
)

# handle vcpkg toolchain file
$VCPKG_SCRIPT = "cmake\find_vcpkg.bat"
if (Test-Path $VCPKG_SCRIPT) {
    $TOOLCHAIN_FILE = & cmd.exe /c $VCPKG_SCRIPT
    if (($TOOLCHAIN_FILE -ne "vcpkg config not found") -and (Test-Path $VCPKG_SCRIPT)) {
        $CMAKE_ARGS += "-DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN_FILE"
    } else {
        Write-Warning "vcpkg config not found"
    }
} else {
    Write-Warning "find_vcpkg.bat not found"
}

# change to build directory
Push-Location "build\$TRIPLE"

function Invoke-VsDevCmd {
    param ([string]$VsDevCmdPath)

    # import environment variables from vsdevcmd.bat
    $envDump = cmd.exe /c "`"$VsDevCmdPath`" && set"
    foreach ($line in $envDump) {
        if ($line -match "^(.*?)=(.*)$") {
            [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2])
        }
    }
}

# run cmake and build
if ($UseVsDev) {
    # run commands in visual studio developer command prompt
    if ($UseVsDev) {
        Invoke-VsDevCmd -VsDevCmdPath $VsDevCmd
    }

    if ($LlvmConfig) {
        $CMAKE_ARGS += "-DLLVM_CONFIG=$LlvmConfig"
    }

    Write-Host "Running CMake with arguments: cmake $CMAKE_ARGS"
    & cmake @CMAKE_ARGS

    if ($LASTEXITCODE -ne 0) {
        Write-Error "CMake configuration failed."
        Pop-Location
        exit $LASTEXITCODE
    }

    Write-Host "Building with: cmake --build . --parallel $NumThreads"
    & cmake --build . --parallel $NumThreads
} else {
    # run commands directly
    Write-Host "Running CMake with arguments: cmake $CMAKE_ARGS"
    & cmake $CMAKE_ARGS

    Write-Host "Building with: cmake --build . --parallel $NumThreads"
    & cmake --build . --parallel $NumThreads
}

# change back to project root
Pop-Location

# copy folders from lib-helix to build\$triple
if (Test-Path "lib-helix") {
    Get-ChildItem -Path "lib-helix" -Directory | ForEach-Object {
        if ($_.Name -ne "lib-helix") {
            Copy-Item -Path $_.FullName -Destination "build\$TRIPLE" -Recurse -Force
        }
    }
}

# delete files in build\$triple, leaving directories
Get-ChildItem -Path "build\$TRIPLE" -File | Remove-Item -Force

Write-Host "Build completed successfully for $TRIPLE in $BuildType mode"
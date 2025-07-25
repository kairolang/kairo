#!/bin/bash

# Exit on any error
set -e

# Function to print usage
usage() {
    echo "Usage: $0 [-debug|-release] [-llvm-config=<path_to_llvm_config>]"
    exit 1
}

# Parse command-line arguments
BUILD_TYPE="Release"
LLVM_CONFIG=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -debug) BUILD_TYPE="Debug" ;;
        -release) BUILD_TYPE="Release" ;;
        -llvm-config=*) LLVM_CONFIG="${1#-llvm-config=}" ;;
        *) usage ;;
    esac
    shift
done

# Determine the platform and set target triple
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$OS" in
    linux*) 
        TRIPLE="$ARCH-linux-gnu"
        ;;
    darwin*) 
        TRIPLE="$ARCH-apple-llvm"
        ;;
    *) 
        echo "Unsupported OS: $OS. Use build.ps1 or build.bat on Windows."
        exit 1
        ;;
esac

# Create build directories
mkdir -p build
mkdir -p "build/$TRIPLE"

# Change to the build directory
cd "build/$TRIPLE"

rm -rf * # clear all the files in the dir

# Prepare CMake command
CMAKE_ARGS=("-G" "Ninja" "-DCMAKE_BUILD_TYPE=$BUILD_TYPE" "../../")

# Add LLVM_CONFIG if provided
if [[ -n "$LLVM_CONFIG" ]]; then
    CMAKE_ARGS+=("-DLLVM_CONFIG=$LLVM_CONFIG")
fi

# Run CMake
cmake "${CMAKE_ARGS[@]}"

# Build the project
cmake --build . --config "$BUILD_TYPE" --parallel

# Change back to project root
cd ../../

# Copy folders (not files) from lib-helix to build/$TRIPLE
if [[ -d "lib-helix" ]]; then
    find lib-helix -maxdepth 1 -type d -not -path "lib-helix" -exec cp -r {} "build/$TRIPLE/" \;
fi

# Delete all files in build/$TRIPLE, leaving only directories
find "build/$TRIPLE" -maxdepth 1 -type f -delete

echo "Build completed successfully for $TRIPLE in $BUILD_TYPE mode"
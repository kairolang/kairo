#!/usr/bin/env bash
set -euo pipefail

ROOT="${KBLD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BUILD_DIR="${KBLD_BUILD_DIR:-$ROOT/build}"
TRIPLE="${KBLD_TRIPLE:-arm64-darwin-macho}"
MODE="${KBLD_MODE:-release}"
JOBS="${KBLD_JOBS:-$(sysctl -n hw.logicalcpu)}"

LLVM_SRC="$ROOT/Lib/llvm-runtimes"
LLVM_BUILD="$BUILD_DIR/llvm"
LLVM_MARKER="$LLVM_BUILD/lib/libLLVM.dylib"
OUT_LIB="$BUILD_DIR/$TRIPLE/$MODE/lib"
LINK_JOBS="${LINK_JOBS:-$JOBS}"

echo "[llvm] root:       $ROOT"
echo "[llvm] triple:     $TRIPLE"
echo "[llvm] mode:       $MODE"
echo "[llvm] out_lib:    $OUT_LIB"
echo "[llvm] jobs:       $JOBS"
echo "[llvm] link_jobs:  $LINK_JOBS"

# ── check submodule ────────────────────────────────────────────────────────────
if [[ ! -f "$LLVM_SRC/llvm/CMakeLists.txt" ]]; then
    echo "[llvm] error: Lib/llvm-runtimes submodule not initialised"
    echo "[llvm] run: git submodule update --init --recursive Lib/llvm-runtimes"
    exit 1
fi

# ── copy + fix install names helper ───────────────────────────────────────────
copy_libs() {
    local src="$1"
    mkdir -p "$OUT_LIB"
    cp -P "$src"/libLLVM*.dylib  "$OUT_LIB/" 2>/dev/null || true
    cp -P "$src"/libclang*.dylib "$OUT_LIB/" 2>/dev/null || true
    cp -P "$src"/liblld*.dylib   "$OUT_LIB/" 2>/dev/null || true

    # fix install names so @rpath works from any install location
    for dylib in "$OUT_LIB"/lib*.dylib; do
        [[ -f "$dylib" ]] || continue
        base="$(basename "$dylib")"
        install_name_tool -id "@rpath/$base" "$dylib" 2>/dev/null || true
    done
    echo "[llvm] libs copied and install names fixed in $OUT_LIB"
}

# ── skip if already built ──────────────────────────────────────────────────────
if [[ -f "$LLVM_MARKER" ]]; then
    echo "[llvm] submodule build exists, skipping rebuild."
    copy_libs "$LLVM_BUILD/lib"
    exit 0
fi

# ── check system llvm ABI ──────────────────────────────────────────────────────
use_system=0
if command -v llvm-config &>/dev/null; then
    sys_libdir="$(llvm-config --libdir 2>/dev/null | tr -d '\n\r ')"
    sys_lib="$(ls "$sys_libdir"/libLLVM*.dylib 2>/dev/null | head -1 || true)"

    if [[ -n "$sys_lib" ]]; then
        if otool -L "$sys_lib" 2>/dev/null | grep -q "libc++"; then
            echo "[llvm] system LLVM uses libc++ - using system."
            use_system=1
        else
            echo "[llvm] system LLVM does not use libc++ - building from source."
        fi
    else
        echo "[llvm] llvm-config found but no libLLVM.dylib - building from source."
    fi
else
    echo "[llvm] llvm-config not found - building from source."
fi

if [[ "$use_system" -eq 1 ]]; then
    copy_libs "$sys_libdir"
    exit 0
fi

# ── targets - mac always builds universal ─────────────────────────────────────
TARGETS="${LLVM_TARGETS:-X86;AArch64;WebAssembly}"
echo "[llvm] targets: $TARGETS"

# ── configure ─────────────────────────────────────────────────────────────────
echo "[llvm] configuring..."
cmake \
    -S "$LLVM_SRC/llvm" \
    -B "$LLVM_BUILD" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DLLVM_ENABLE_LIBCXX=ON \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_TARGETS_TO_BUILD="$TARGETS" \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_LTO=Thin \
    -DLLVM_PARALLEL_LINK_JOBS="$LINK_JOBS"

# ── build ──────────────────────────────────────────────────────────────────────
echo "[llvm] building with $JOBS jobs..."
ninja -C "$LLVM_BUILD" -j"$JOBS"

copy_libs "$LLVM_BUILD/lib"
echo "[llvm] done."

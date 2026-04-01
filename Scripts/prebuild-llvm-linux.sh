#!/usr/bin/env bash
set -euo pipefail

ROOT="${KBLD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BUILD_DIR="${KBLD_BUILD_DIR:-$ROOT/build}"
TRIPLE="${KBLD_TRIPLE:-x86_64-linux-gnu}"
MODE="${KBLD_MODE:-release}"
JOBS="$(nproc)"

LLVM_SRC="$ROOT/Lib/llvm-runtimes"
LLVM_BUILD="$BUILD_DIR/llvm"
LLVM_MARKER="$LLVM_BUILD/lib/libLLVM.so"
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

# ── copy helper ────────────────────────────────────────────────────────────────
copy_libs() {
    local src="$1"
    mkdir -p "$OUT_LIB"
    cp -P "$src"/libLLVM*.so*  "$OUT_LIB/" 2>/dev/null || true
    cp -P "$src"/libclang*.so* "$OUT_LIB/" 2>/dev/null || true
    cp -P "$src"/liblld*.so*   "$OUT_LIB/" 2>/dev/null || true
    echo "[llvm] libs copied to $OUT_LIB"
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
    sys_lib="$(ls "$sys_libdir"/libLLVM*.so 2>/dev/null | head -1 || true)"

    if [[ -n "$sys_lib" ]]; then
        if ldd "$sys_lib" 2>/dev/null | grep -q "libc++.so"; then
            echo "[llvm] system LLVM uses libc++ - using system."
            use_system=1
        elif ldd "$sys_lib" 2>/dev/null | grep -q "libstdc++.so"; then
            echo "[llvm] system LLVM uses libstdc++ - ABI mismatch, building from source."
        else
            # ldd inconclusive - check nm
            if ! nm -D "$sys_lib" 2>/dev/null | grep -q "GLIBCXX"; then
                echo "[llvm] system LLVM uses libc++ (nm check) - using system."
                use_system=1
            else
                echo "[llvm] system LLVM uses libstdc++ (nm check) - building from source."
            fi
        fi
    else
        echo "[llvm] llvm-config found but no libLLVM.so - building from source."
    fi
else
    echo "[llvm] llvm-config not found - building from source."
fi

if [[ "$use_system" -eq 1 ]]; then
    copy_libs "$sys_libdir"
    exit 0
fi

# ── detect targets ─────────────────────────────────────────────────────────────
ARCH="${KBLD_ARCH:-$(uname -m)}"
# case "$ARCH" in
#     x86_64)  HOST_TARGET="X86;AArch64;ARM;RISCV;WebAssembly" ;;
#     aarch64) HOST_TARGET="AArch64" ;;
#     armv7*)  HOST_TARGET="ARM" ;;
#     riscv64) HOST_TARGET="RISCV" ;;
#     *)       HOST_TARGET="X86" ;;
# esac
HOST_TARGET="X86;AArch64;ARM;RISCV;WebAssembly"

TARGETS="${LLVM_TARGETS:-$HOST_TARGET}"
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
    -DLLVM_USE_SPLIT_DWARF=ON \
    -DLLVM_ENABLE_LTO=Thin \
    -DLLVM_PARALLEL_LINK_JOBS="$LINK_JOBS"

# ── build ──────────────────────────────────────────────────────────────────────
echo "[llvm] building with $JOBS jobs..."
ninja -C "$LLVM_BUILD" -j"$JOBS"

copy_libs "$LLVM_BUILD/lib"
echo "[llvm] done."
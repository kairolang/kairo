#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LLVM_SRC="$PROJECT_ROOT/Lib/llvm-runtimes"
LLVM_BUILD="$PROJECT_ROOT/build/llvm"
LLVM_MARKER="$LLVM_BUILD/lib/libLLVM.so"

echo "[llvm] project root: $PROJECT_ROOT"

# ── check submodule ────────────────────────────────────────────────────────────
if [[ ! -f "$LLVM_SRC/llvm/CMakeLists.txt" ]]; then
    echo "[llvm] error: Lib/llvm-runtimes submodule not initialised"
    echo "[llvm] run: git submodule update --init --recursive Lib/llvm-runtimes"
    exit 1
fi

# ── skip if already built ──────────────────────────────────────────────────────
if [[ -f "$LLVM_MARKER" ]]; then
    echo "[llvm] already built, skipping. delete $LLVM_BUILD to rebuild."
    exit 0
fi

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
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64;WebAssembly" \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_USE_SPLIT_DWARF=ON \
    -DLLVM_ENABLE_LTO=Thin \
    -DLLVM_PARALLEL_LINK_JOBS=24

# ── build ──────────────────────────────────────────────────────────────────────
echo "[llvm] building with $(nproc) jobs..."
ninja -C "$LLVM_BUILD" -j"$(nproc)"

# ── copy libs to build output ──────────────────────────────────────────────────
OUT_LIB="$PROJECT_ROOT/build/x86_64-linux-gnu/release/lib"
mkdir -p "$OUT_LIB"

echo "[llvm] copying libs to $OUT_LIB..."
cp -P "$LLVM_BUILD"/lib/libLLVM*.so*   "$OUT_LIB/" 2>/dev/null || true
cp -P "$LLVM_BUILD"/lib/libclang*.so*  "$OUT_LIB/" 2>/dev/null || true
cp -P "$LLVM_BUILD"/lib/liblld*.so*    "$OUT_LIB/" 2>/dev/null || true

echo "[llvm] done."
echo ""
echo "add these to your build flags:"
echo "  includes:"
echo "    $LLVM_BUILD/include"
echo "    $LLVM_SRC/llvm/include"
echo "    $LLVM_SRC/clang/include"
echo "    $LLVM_BUILD/tools/clang/include"
echo "  link_dir: $OUT_LIB"
echo "  libs: clang-cpp LLVM lld"
echo "  rpath: -Wl,-rpath,\$ORIGIN/../lib"
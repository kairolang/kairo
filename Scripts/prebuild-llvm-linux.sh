#!/usr/bin/env bash
# TOOLCHAIN LINKAGE INVARIANT - do not violate:
#   Linux/macOS : shared (libLLVM.so/.dylib), one copy in lib/, thin bins
#   Windows     : static (.lib), forced - libLLVM.dll is unsupported on Windows
#   No system-LLVM fallback on any platform (patched fork required).
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

for tool in cmake ninja; do
    if ! command -v "$tool" &>/dev/null; then
        echo "[llvm] error: '$tool' not found."
        echo "[llvm]   macOS:  brew install cmake ninja"
        echo "[llvm]   Arch:   sudo pacman -S cmake ninja"
        echo "[llvm]   Debian: apt install cmake ninja-build"
        exit 1
    fi
done

# verify submodule is actually checked out
# Not just "dir exists", a non-recursive or half-failed init leaves an empty
# or partial tree. Check the real source is present.
if [[ ! -f "$LLVM_SRC/llvm/CMakeLists.txt" ]]; then
    echo "[llvm] error: Lib/llvm-runtimes is not checked out."
    echo "[llvm] this is our PATCHED llvm-project fork (custom Clang PP-token"
    echo "[llvm] injection). it is REQUIRED, there is no system-LLVM fallback."
    echo "[llvm] run: git submodule update --init --recursive Lib/llvm-runtimes"
    exit 1
fi

# copy helper
copy_libs() {
    local src="$1"
    mkdir -p "$OUT_LIB"
    cp -P "$src"/libLLVM*.so*  "$OUT_LIB/" 2>/dev/null || true
    cp -P "$src"/libclang*.so* "$OUT_LIB/" 2>/dev/null || true
    cp -P "$src"/liblld*.so*   "$OUT_LIB/" 2>/dev/null || true
    echo "[llvm] libs copied to $OUT_LIB"
}

# skip if already built
if [[ -f "$LLVM_MARKER" ]]; then
    echo "[llvm] patched llvm already built, skipping rebuild."
    copy_libs "$LLVM_BUILD/lib"
    exit 0
fi

# why we always build from source
echo ""
echo "[llvm] ============================================================"
echo "[llvm]  BUILDING PATCHED LLVM FROM SOURCE"
echo "[llvm] ------------------------------------------------------------"
echo "[llvm]  Kairo links our llvm-project fork, which carries a custom"
echo "[llvm]  Clang patch (preprocessor token injection) that the Kairo"
echo "[llvm]  frontend depends on. System LLVM does NOT have this patch"
echo "[llvm]  and would produce a silently broken compiler, so there is"
echo "[llvm]  no system fallback path. This is a one-time build."
echo "[llvm]  Expect 20-60 min depending on cores. Output streams below."
echo "[llvm] ============================================================"
echo ""

# detect targets
HOST_TARGET="X86;AArch64;ARM;RISCV;WebAssembly"
TARGETS="${LLVM_TARGETS:-$HOST_TARGET}"
echo "[llvm] targets: $TARGETS"

# configure
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
    -DLLVM_ENABLE_RTTI=ON \
    -DLLVM_ENABLE_EH=ON \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_OPTIMIZED_TABLEGEN=ON \
    -DCLANG_BUILD_TOOLS=OFF \
    -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_ZLIB=FORCE_ON \
    -DLLVM_ENABLE_ZSTD=FORCE_ON \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_USE_SPLIT_DWARF=ON \
    -DLLVM_ENABLE_LTO=Thin \
    -DLLVM_PARALLEL_LINK_JOBS="$LINK_JOBS"

# build (streams live)
echo "[llvm] building with $JOBS jobs..."
ninja -C "$LLVM_BUILD" -j"$JOBS"

copy_libs "$LLVM_BUILD/lib"
echo "[llvm] done."
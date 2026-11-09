#!/usr/bin/env bash
# Build a macOS sysroot (arm64, arm64e, x86_64) for this Kairo install from
# YOUR Apple SDK, plus libc++/libc++abi and compiler-rt builtins compiled
# against it from the LLVM runtimes source that ships in
# <install>/share/kairo/runtimes.
#
# Kairo cannot ship these roots: Apple's SDK license forbids redistributing
# the SDK. On a Mac with the Xcode Command Line Tools (xcode-select --install):
#
#   <install>/scripts/darwin-sysroot.sh arm64                 (or: x86_64 arm64e, several at once)
#
# and `kairo --target arm64-apple-macosx main.k -o main` finds the root with
# no flags. The SDK comes from `xcrun --sdk macosx --show-sdk-path`, or from
# SDK=<path to MacOSX.sdk>; with SDK= set the script also runs off-Mac (you
# still need a copy of the SDK you are licensed to use).
#
# Layout is SDK-shaped, not flattened: libSystem.tbd re-exports
# /usr/lib/system/*.dylib by install name and the linker resolves those (and
# frameworks) under -syslibroot, which the driver sets to this root.
#
# Ours, not Apple's: libc++/libc++abi (LLVM 22, static, hermetic) replace the
# SDK's, and compiler-rt TF + bf16 builtins fill what libSystem lacks
# (binary128, bf16 conversions).
#
# Toolchain: only this install's own tools. kcc (the Kairo C/C++ driver)
# replaces clang/clang++ for every compile; kld (-flavor darwin) replaces
# ld64.lld for the symbol probe; llvm-ar (--format=darwin) and llvm-ranlib
# replace Apple's libtool. No host compiler, LLVM install or Kairo checkout is
# used. Runs under macOS's stock /bin/bash (3.2).
#
# sh only: there is no PowerShell half. On Windows run it under WSL with SDK=.
#
# Host requirements: bash, cmake (3.20+), ninja, python3 (the LLVM runtimes
# build needs it), and the usual POSIX tools; xcrun when SDK= is not given.
#
# Usage: <install>/scripts/darwin-sysroot.sh [arm64|arm64e|x86_64 ...]
#   SDK=...        default: xcrun --sdk macosx --show-sdk-path
#   OUT=...        default: <install>/sysroot; each root lands in OUT/<arch>-apple-macosx
#   MIN_MACOS=...  default: 11.0 (arm64, arm64e), 10.15 (x86_64)
#   WORK=...       build scratch (default: <install>/.sysroot-work/darwin; removed on success)
#   JOBS=...       parallel compile jobs (default: CPU count, at most 8)
#   KEEP_WORK=1    keep the build scratch after a successful run
set -euo pipefail

die() { echo "!! $*" >&2; exit 1; }

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*|Windows*)
    die "darwin-sysroot.sh needs a macOS host, or Linux/WSL with SDK=<path to MacOSX.sdk>; Windows itself is not supported (for Windows targets use msvc-sysroot.ps1)" ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
KAIRO="$(cd "$HERE/.." && pwd -P)"
BIN="$KAIRO/bin"
KCC="$BIN/kcc"; KLD="$BIN/kld"; LLVM_AR="$BIN/llvm-ar"; LLVM_RANLIB="$BIN/llvm-ranlib"
SRC="$KAIRO/share/kairo/runtimes"
STAGE="${OUT:-$KAIRO/sysroot}"
WORK="${WORK:-$KAIRO/.sysroot-work/darwin}"

[ $# -eq 0 ] && set -- arm64

for t in "$KCC" "$KLD" "$LLVM_AR" "$LLVM_RANLIB"; do
  [ -x "$t" ] || die "$t is missing: run this script from inside a Kairo install (<install>/scripts/darwin-sysroot.sh)"
done
[ -f "$SRC/runtimes/CMakeLists.txt" ] || die "no LLVM runtimes source at $SRC (it ships in the release archive)"
for t in cmake ninja python3 find cp tar sed grep du mkdir; do
  command -v "$t" >/dev/null 2>&1 || die "need '$t' on PATH (cmake and ninja: Homebrew, MacPorts or your package manager)"
done
if [ -z "${SDK:-}" ]; then
  [ "$(uname -s)" = Darwin ] || die "run on macOS, or set SDK=<path to MacOSX.sdk>"
  command -v xcrun >/dev/null 2>&1 || die "no xcrun: install the Command Line Tools (xcode-select --install) or set SDK="
  SDK="$(xcrun --sdk macosx --show-sdk-path)" || die "xcrun found no macOS SDK; set SDK="
fi
SDK="$(cd "$SDK" && pwd -P)" || die "SDK=$SDK does not exist"   # MacOSX.sdk -> MacOSX26.x.sdk
[ -f "$SDK/SDKSettings.json" ] || die "$SDK is not an SDK (no SDKSettings.json)"
[ -f "$SDK/usr/lib/libSystem.tbd" ] || die "$SDK has no usr/lib/libSystem.tbd"

if [ -z "${JOBS:-}" ]; then
  JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
  [ "$JOBS" -gt 8 ] && JOBS=8
fi
# kcc looks for <install>/sysroot/<target> on its own; pointing it at an empty
# root keeps the build hermetic. kcc compiles with -nostdsysteminc, so the
# SDK's usr/include is named explicitly, after clang's resource headers.
NOROOT="$WORK/noroot"
SDK_FLAGS="--sysroot=$NOROOT -isysroot $SDK -idirafter $SDK/usr/include"

# Binary128 needs the fork's HasFloat128 on the Darwin target of EACH arch;
# without it compiler-rt's int_types.h finds no tf_float and the TF sources
# compile empty. kcc is built from that fork, so this only fails on a broken
# install; checked per arch before anything is staged.
check_float128() {   # $1 = arch, $2 = min
  # No grep -q under pipefail: an early exit SIGPIPEs the producer.
  "$KCC" --sysroot="$NOROOT" --target="$1-apple-macos$2" -dM -E -x c /dev/null | grep __SIZEOF_FLOAT128__ >/dev/null \
    || die "kcc has no __float128 on $1-apple-macos (this install's kcc is not the patched fork)"
}

emit_toml() {
  cat >"$2" <<EOF
triple        = "$1"
llvm_version  = "22.1.0"
family        = "darwin"
sysroot       = "."
resource_dir  = "clang"
redistributable = false
include_dirs  = ["usr/include/c++/v1", "usr/include"]
lib_dirs      = ["usr/lib"]
has_libcxx    = true
static        = false
crt_startup   = []
crt_end       = []
libc_link     = ["-lSystem"]
libcxx_link   = ["-lc++"]
rtlib         = "compiler-rt"
linker        = "lld"
cc_isolation  = ["-nostdlibinc", "-nostdinc++"]
EOF
}

# copy_tree <src dir> <dst dir> [tar --exclude patterns...]: tar, not rsync
# (not every host has rsync). Keeps symlinks.
copy_tree() {
  local src="$1" dst="$2" p
  shift 2
  set -- "$@" --
  # Rebuild "$@" as --exclude <p> pairs (no arrays: bash 3.2 + set -u).
  while [ "$1" != -- ]; do p="$1"; shift; set -- "$@" --exclude "$p"; done
  shift
  mkdir -p "$dst"
  (cd "$src" && tar cf - "$@" .) | (cd "$dst" && tar xf -)
}

stage_sdk() {   # $1 = dst
  local dst="$1"
  mkdir -p "$dst/usr" "$dst/System/Library"
  cp "$SDK/SDKSettings.json" "$dst/"
  if [ -f "$SDK/SDKSettings.plist" ]; then cp "$SDK/SDKSettings.plist" "$dst/"; fi
  # Apple's libc++ headers out: ours go in their place.
  copy_tree "$SDK/usr/include" "$dst/usr/include" 'c++'
  # .tbd stubs only; Apple's libc++/libc++abi out (the linker prefers a
  # dylib/tbd over our .a in the same dir), swift out.
  copy_tree "$SDK/usr/lib" "$dst/usr/lib" 'swift' 'libc++*.tbd'
  if [ -d "$SDK/System/Library/Frameworks" ]; then
    copy_tree "$SDK/System/Library/Frameworks" "$dst/System/Library/Frameworks" \
      '*.swiftmodule' '*.swiftinterface' '*.swiftdoc' '*.abi.json'
  fi
}

build_libcxx() {   # $1 = arch, $2 = min, $3 = dst
  local arch="$1" min="$2" dst="$3" b="$WORK/libcxx-$arch"
  rm -rf "$b"; mkdir -p "$b"
  echo ">> [$arch] configuring libc++"
  # Cross-style configure on every host (CMAKE_SYSTEM_NAME=Darwin): kcc
  # cannot link a Darwin program until this root exists, so try_compile is
  # compile-only, and nothing here asks xcrun or Apple's libtool/ranlib.
  cmake -G Ninja -S "$SRC/runtimes" -B "$b" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$arch" \
    -DCMAKE_C_COMPILER="$KCC" -DCMAKE_CXX_COMPILER="$KCC" -DCMAKE_ASM_COMPILER="$KCC" \
    -DCMAKE_C_COMPILER_TARGET="$arch-apple-macos$min" \
    -DCMAKE_CXX_COMPILER_TARGET="$arch-apple-macos$min" \
    -DCMAKE_ASM_COMPILER_TARGET="$arch-apple-macos$min" \
    -DCMAKE_C_FLAGS="$SDK_FLAGS" -DCMAKE_CXX_FLAGS="$SDK_FLAGS" -DCMAKE_ASM_FLAGS="$SDK_FLAGS" \
    -DCMAKE_AR="$LLVM_AR" -DCMAKE_RANLIB="$LLVM_RANLIB" \
    -DCMAKE_C_ARCHIVE_FINISH="<CMAKE_RANLIB> <TARGET>" \
    -DCMAKE_CXX_ARCHIVE_FINISH="<CMAKE_RANLIB> <TARGET>" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$min" \
    -DCMAKE_INSTALL_PREFIX="$dst/usr" \
    -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_SHARED=OFF \
    -DLIBCXX_ENABLE_STATIC=ON  -DLIBCXXABI_ENABLE_STATIC=ON \
    -DLIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON \
    -DLIBCXX_HERMETIC_STATIC_LIBRARY=ON \
    -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
    -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
    -DLIBCXX_INCLUDE_DOCS=OFF -DLIBCXXABI_INCLUDE_TESTS=OFF \
    -DLIBCXX_INSTALL_LIBRARY_DIR=lib -DLIBCXXABI_INSTALL_LIBRARY_DIR=lib \
    -DLIBCXX_INSTALL_INCLUDE_DIR=include/c++/v1 \
    -DLIBCXX_INSTALL_INCLUDE_TARGET_DIR=include/c++/v1 \
    >"$b/configure.log" 2>&1 \
    || { tail -30 "$b/configure.log" >&2; die "[$arch] configure failed ($b/configure.log)"; }
  echo ">> [$arch] building libc++ (-j$JOBS)"
  ninja -C "$b" -j "$JOBS" install-cxx install-cxxabi >"$b/build.log" 2>&1 \
    || { grep -m30 -A8 "^FAILED" "$b/build.log" | grep -v "^/" >&2; die "[$arch] build failed ($b/build.log)"; }
  # Merged into libc++.a; a separate one would only invite a double link.
  rm -f "$dst/usr/lib/libc++abi.a"
}

build_tf_builtins() {   # $1 = arch, $2 = min, $3 = dst
  local arch="$1" min="$2" dst="$3" b="$WORK/tf-$arch"
  local B="$SRC/compiler-rt/lib/builtins"
  local srcs bf f
  srcs=$(sed -n '/^set(GENERIC_TF_SOURCES/,/)/p' "$B/CMakeLists.txt" | grep -oE '[a-z0-9_]+\.c' || true)
  [ -n "$srcs" ] || die "GENERIC_TF_SOURCES not found in $B/CMakeLists.txt"
  # bf16 conversions: libSystem exports none, and x86_64 lowers float->bf16
  # to a __truncsfbf2 libcall (AArch64 happens to expand it inline).
  bf=$(sed -n '/^set(BF16_SOURCES/,/)/p' "$B/CMakeLists.txt" | grep -oE '[a-z0-9_]+\.c' || true)
  [ -n "$bf" ] || die "BF16_SOURCES not found in $B/CMakeLists.txt"
  srcs="$srcs $bf"
  rm -rf "$b"; mkdir -p "$b" "$dst/clang/lib/darwin"
  # The TF routines round through __fe_getround / __fe_raise_inexact, which
  # live in the arch's fp_mode.c (x86_64 shares i386's, as in compiler-rt's
  # x86_ARCH_SOURCES). libSystem does not export them, so they ship here too.
  case "$arch" in
    arm64*) srcs="$srcs aarch64/fp_mode.c" ;;
    x86_64) srcs="$srcs i386/fp_mode.c" ;;
  esac
  echo ">> [$arch] building TF + bf16 builtins"
  for f in $srcs; do
    # shellcheck disable=SC2086
    "$KCC" --target="$arch-apple-macos$min" $SDK_FLAGS \
      -O2 -fPIC -ffreestanding -fno-builtin -fvisibility=hidden \
      -c "$B/$f" -o "$b/$(basename "${f%.c}").o" \
      || die "[$arch] $f failed to compile"
  done
  local a="$dst/clang/lib/darwin/libclang_rt.osx.a"
  rm -f "$a"
  "$LLVM_AR" --format=darwin rcs "$a" "$b"/*.o || die "[$arch] llvm-ar failed"
  "$LLVM_RANLIB" "$a" || die "[$arch] llvm-ranlib failed"
  probe_builtins "$arch" "$min" "$dst" "$a" __addtf3 __fe_getround __truncsfbf2
}

# Symbol check without nm: a probe that calls every required builtin, linked by kld (ld64 flavor) against the archive and libSystem. An
# undefined symbol fails the link, which is exactly "the archive lacks it".
probe_builtins() {   # $1 = arch, $2 = min, $3 = dst, $4 = archive, $5... = symbols
  local arch="$1" min="$2" dst="$3" a="$4" w="$WORK/probe-$1" s
  shift 4
  rm -rf "$w"; mkdir -p "$w"
  {
    # Calls, not an address table: on arm64e a data pointer is a signed
    # (authenticated) relocation, which the linker does not take.
    for s in "$@"; do echo "extern void $s(void);"; done
    echo "__attribute__((visibility(\"default\"))) void kairo_probe(void) {"
    for s in "$@"; do echo "  $s();"; done
    echo "}"
  } >"$w/probe.c"
  # shellcheck disable=SC2086
  "$KCC" --target="$arch-apple-macos$min" $SDK_FLAGS -O0 -c "$w/probe.c" -o "$w/probe.o" \
    || die "[$arch] symbol probe failed to compile"
  "$KLD" -flavor darwin -arch "$arch" -platform_version macos "$min" "$min" -dylib \
    -syslibroot "$dst" -L"$dst/usr/lib" -o "$w/probe.dylib" "$w/probe.o" "$a" -lSystem \
    >"$w/probe.log" 2>&1 \
    || { cat "$w/probe.log" >&2; die "[$arch] builtins lack a required symbol (TF/bf16/fp_mode sources compiled empty?)"; }
}

# The Kairo-shaped check: C++ with a thrown and caught exception, compiled
# and linked by kcc from SYSROOT.toml alone (no include or library flags).
# The target names the deployment version: a bare arm64-apple-macosx means an
# old macOS without thread-local storage, which the Kairo runtime needs.
validate() {   # $1 = triple, $2 = dst, $3 = min
  local triple="$1$3" r="$2" t="$WORK/$1-test"
  mkdir -p "$t"
  cat >"$t/t.cpp" <<'EOF'
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>
int main() {
  std::vector<std::string> v{"a", "b"};
  try { throw std::runtime_error(v[0] + v[1]); }
  catch (const std::exception &e) { std::printf("%s\n", e.what()); }
  return 0;
}
EOF
  case "$1" in
    arm64e-*)
      # kld (lld's Mach-O port) does not take arm64e's signed-pointer
      # relocations yet, so arm64e is checked as far as the compile.
      "$KCC" --target="$triple" --sysroot="$r" -std=c++20 -O1 -c "$t/t.cpp" -o "$t/t.o" >"$t/link.log" 2>&1 \
        || { cat "$t/link.log" >&2; die "[$triple] validation compile failed (kcc --target=$triple --sysroot=$r)"; }
      echo "   validated: kcc compiled a C++ program from SYSROOT.toml (not linked: kld cannot link arm64e yet)" ;;
    *)
      "$KCC" --target="$triple" --sysroot="$r" -std=c++20 -O1 "$t/t.cpp" -o "$t/t" >"$t/link.log" 2>&1 \
        || { cat "$t/link.log" >&2; die "[$triple] validation link failed (kcc --target=$triple --sysroot=$r)"; }
      echo "   validated: kcc linked a C++ program from SYSROOT.toml ($t/t)" ;;
  esac
}

echo ">> install: $KAIRO"
echo ">> runtimes source: $SRC (rev $(cat "$SRC/REVISION" 2>/dev/null || echo unknown))"
mkdir -p "$NOROOT"
for arch in "$@"; do
  case "$arch" in
    arm64)  min="${MIN_MACOS:-11.0}" ;;
    # Pointer-authentication ABI (Xcode 26 "Enhanced Security"). The fork's
    # driver turns on the -fptrauth-* set for an arm64e triple, so libc++
    # and the TF builtins come out signed with no extra flags here.
    arm64e) min="${MIN_MACOS:-11.0}" ;;
    x86_64) min="${MIN_MACOS:-10.15}" ;;
    *) die "unknown arch $arch (arm64, arm64e, x86_64)" ;;
  esac
  check_float128 "$arch" "$min"
  triple="$arch-apple-macosx"
  dst="$STAGE/$triple"
  echo ">> [$triple] staging from $SDK (min $min) -> $dst"
  # Assembled under WORK and moved into place only when complete: kcc picks
  # up <install>/sysroot/<triple> by itself (ahead of --sysroot), so neither
  # an old root nor a half-built one may sit there during the build.
  root="$WORK/$triple-root"
  rm -rf "$dst" "$root"; mkdir -p "$root"
  stage_sdk "$root"
  build_libcxx "$arch" "$min" "$root"
  build_tf_builtins "$arch" "$min" "$root"
  emit_toml "$triple" "$root/SYSROOT.toml"
  mkdir -p "$STAGE"; mv "$root" "$dst"

  [ -f "$dst/usr/include/stdio.h" ]       || die "[$triple] no stdio.h"
  [ -f "$dst/usr/include/c++/v1/vector" ] || die "[$triple] no libc++ headers"
  [ -f "$dst/usr/lib/libSystem.tbd" ]     || die "[$triple] no libSystem.tbd"
  [ -d "$dst/usr/lib/system" ]            || die "[$triple] no usr/lib/system"
  [ -f "$dst/usr/lib/libc++.a" ]          || die "[$triple] no libc++.a"
  if ls "$dst"/usr/lib/libc++*.tbd >/dev/null 2>&1; then die "[$triple] Apple libc++ stub leaked"; fi
  validate "$triple" "$dst" "$min"
  echo ">> [$triple] staged ($(du -sh "$dst" | cut -f1))"
done
if [ "${KEEP_WORK:-0}" != 1 ]; then rm -rf "$WORK"; rmdir "$(dirname "$WORK")" 2>/dev/null || true; fi
echo "darwin sysroots ready. Try: kairo --target ${triple:-arm64-apple-macosx}${min:-11.0} main.k -o main"
echo "(They contain Apple's SDK: keep them local, never redistribute them.)"

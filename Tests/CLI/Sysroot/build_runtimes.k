// The builtins and runtimes stages (Compiler/Spec/SysRoot.md 4.5, 4.7) compile
// compiler-rt builtins + crtbegin/crtend, libunwind, libc++abi and libc++ from the
// share tree's runtimes source with the runtimes-recipe/ tables: no CMake, no ninja,
// no bundled root to copy from. `ksys build x86_64-linux-musl --out DIR` from a
// toolchain prefix with no sysroot/ (the driver prefers <prefix>/sysroot/<name> over
// --sysroot), against a release-staged runtimes source (Inputs/ksys_env_rt.py):
// every runtime archive and crt object lands where the curated root has it, the
// c++/v1 headers carry their __config_site, archive members are named by basename
// (llvm-ar's naming; a whole path would put the stage dir in every archive), and the
// root validates by running t.cpp natively. A target the tables were not derived for
// is refused up front, before any stage, and -j wants a number.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64
// RUN: rm -rf %t && python3 %S/Inputs/ksys_env_rt.py %ksys %sysgen_share %t
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share "$@"' > %t/ksys.sh
//
// RUN: sh %t/ksys.sh -j 8 build x86_64-linux-musl --out %t/root > %t/out 2> %t/err
// RUN: %FileCheck %s --check-prefix=STAGES < %t/err
// STAGES:      ksys: x86_64-linux-musl: stage builtins
// STAGES-NEXT: ksys: x86_64-linux-musl: stage libc-libs
// STAGES-NEXT: ksys: x86_64-linux-musl: stage runtimes
// STAGES:      ksys: x86_64-linux-musl: validate: t.cpp:        built, ran, exit 12
// STAGES-NEXT: ksys: x86_64-linux-musl: validate: test.k:       built, ran, exit 0
//
// RUN: cd %t/root && test -f lib/libc++.a && test -f lib/libc++abi.a && test -f lib/libunwind.a && test -f lib/libc++experimental.a
// RUN: cd %t/root/compiler-rt/lib/x86_64-unknown-linux-musl && test -f libclang_rt.builtins.a && test -f clang_rt.crtbegin.o && test -f clang_rt.crtend.o
// RUN: grep -q _LIBCPP_HAS_MUSL_LIBC %t/root/include/c++/v1/__config_site
// RUN: test -f %t/root/include/c++/v1/vector && test ! -e %t/root/include/c++/v1/c++
//
// RUN: %t/tc/bin/llvm-nm -A %t/root/lib/libc++.a > %t/nm.cxx
// RUN: %FileCheck %s --check-prefix=CXX < %t/nm.cxx
// CXX: /libc++.a:iostream.cpp.o: {{[0-9a-f]+}} {{[A-Z]}} _ZNSt3__14coutE
// RUN: not grep -q 'libc++.a:/' %t/nm.cxx
// RUN: %t/tc/bin/llvm-nm -A %t/root/compiler-rt/lib/x86_64-unknown-linux-musl/libclang_rt.builtins.a > %t/nm.rt
// RUN: %FileCheck %s --check-prefix=RT < %t/nm.rt
// RT: /libclang_rt.builtins.a:divti3.c.o: {{[0-9a-f]+}} T __divti3
// RUN: not grep -q 'builtins.a:/' %t/nm.rt
// RUN: %t/tc/bin/llvm-nm -A %t/root/lib/libc.a > %t/nm.libc
// RUN: %FileCheck %s --check-prefix=LIBC < %t/nm.libc
// LIBC: /libc.a:printf.lo: {{[0-9a-f]+}} T printf
// RUN: not grep -q 'libc.a:/' %t/nm.libc
//
// RUN: { sh %t/ksys.sh build riscv32-linux-musl --out %t/rv 2>&1; echo "exit $?"; } > %t/rv.out
// RUN: %FileCheck %s --check-prefix=NORECIPE < %t/rv.out
// NORECIPE:      ksys: error [P009E]: no runtimes recipe for riscv32-linux-musl in {{.*}}/runtimes-recipe
// NORECIPE-NEXT: ksys: note [P009N]: runtimes-recipe/index.toml lists the targets it was derived for
// NORECIPE-NEXT: exit 2
// RUN: not grep stage %t/rv.out
//
// RUN: { sh %t/ksys.sh -j x build wasm32-wasi --out %t/w 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=JOBS
// JOBS:      ksys: error: -j wants a number of jobs, not x
// JOBS:      exit 1
//
// Only the logs are worth keeping.
// RUN: rm -rf %t/root %t/rt %t/cache

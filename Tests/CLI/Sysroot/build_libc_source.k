// The MinGW and WASI C libraries built from shipped sources (Compiler/Spec/SysRoot.md
// section 20; build/sysroot-share/FORMAT.md "mingw-crt", "wasi-libc"): the mingw
// provider compiles mingw-w64-crt from mingw-crt/<arch>.toml (cpp'd defs, crt objects,
// libmingw*, the UCRT archives merged as the Makefile's MRI ADDLIB merges them, import
// libraries through the in-process dlltool, the mixed import+code archives) and takes
// only what mingw-w64-crt does not build from mingw/crt/<arch>; the wasi provider
// compiles wasi-libc from wasi-libc/<name>.toml and links its shared libraries with
// kld's wasm flavor, libc++ still from wasi/<v>. Both from a toolchain prefix with no
// sysroot/ (Inputs/ksys_env_rt.py), against the real share tree.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64
// RUN: rm -rf %t && python3 %S/Inputs/ksys_env_rt.py %ksys %sysgen_share %t
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share "$@"' > %t/ksys.sh
//
// RUN: sh %t/ksys.sh -j 16 build x86_64-windows-gnu --out %t/mw > %t/mw.out 2> %t/mw.err
// RUN: %FileCheck %s --check-prefix=MW < %t/mw.err
// MW:      ksys: x86_64-windows-gnu: stage libc-libs
// MW:      ksys: x86_64-windows-gnu: validate: structure:    ok
// MW:      ksys: x86_64-windows-gnu: validate: t.cpp:        built
// RUN: grep -q '"mingw-crt=[0-9a-f]*"' %t/mw/.kairo-sysroot.json && test -d %t/mw/LICENSES/mingw-crt
// RUN: cd %t/mw/lib && test -f crt2.o && test -f crt1.o && test -f crtbegin.o && test -f libmingw32.a && test -f libmsvcrt.a
// RUN: cd %t/mw/lib && test -f libwinpthread.a && test -f libssp.a && test -f libomp.dll.a
// RUN: cmp %t/mw/lib/crt2.o %t/mw/lib/crt1.o && cmp %t/mw/lib/libmsvcrt.a %t/mw/lib/libucrt.a
// RUN: %t/tc/bin/llvm-nm -A %t/mw/lib/libmingwex.a > %t/nm.ex
// RUN: %FileCheck %s --check-prefix=EX < %t/nm.ex
// EX: /libmingwex.a:lib64_libmingwex_a-strtopx.o: {{[0-9a-f]+}} T strtold
// RUN: not grep -q 'libmingwex.a:/' %t/nm.ex
// RUN: %t/tc/bin/llvm-nm -A %t/mw/lib/libkernel32.a | %FileCheck %s --check-prefix=K32
// K32: /libkernel32.a:KERNEL32.dll: {{[0-9a-f]+}} T __imp_CreateFileW
// RUN: %t/tc/bin/llvm-nm -A %t/mw/lib/libucrt.a | %FileCheck %s --check-prefix=UCRT
// UCRT: /libucrt.a:api-ms-win-crt-conio-l1-1-0.dll: {{[0-9a-f]+}} T __imp__cputs
//
// RUN: sh %t/ksys.sh -j 16 build wasm32-wasi --out %t/w > %t/w.out 2> %t/w.err
// RUN: %FileCheck %s --check-prefix=WASI < %t/w.err
// WASI:      ksys: wasm32-wasi: stage builtins
// WASI-NEXT: ksys: wasm32-wasi: stage libc-libs
// WASI:      ksys: wasm32-wasi: validate: t.c:          built
// WASI:      ksys: wasm32-wasi: validate: t.cpp:        built
// RUN: grep -q '"wasi-libc=[0-9a-f]*"' %t/w/.kairo-sysroot.json && test -d %t/w/LICENSES/wasi-libc
// RUN: cd %t/w/lib/wasm32-wasi && test -f libc.so && test -f libdl.so && test -f crt1-command.o && test -f eh/libc++.a
// RUN: test "$(head -c 8 %t/w/lib/wasm32-wasi/libm.a)" = '!<arch>' && test "$(wc -c < %t/w/lib/wasm32-wasi/libm.a)" -eq 8
// RUN: test -f %t/w/include/wasm32-wasi/stdio.h && test -f %t/w/include/wasm32-wasi/eh/c++/v1/vector
// RUN: %t/tc/bin/llvm-nm -A %t/w/lib/wasm32-wasi/libc.a | %FileCheck %s --check-prefix=WLIBC
// WLIBC: /libc.a:printf.c.obj: {{[0-9a-f]+}} T printf
//
// Only the logs are worth keeping.
// RUN: rm -rf %t/mw %t/w %t/rt %t/cache

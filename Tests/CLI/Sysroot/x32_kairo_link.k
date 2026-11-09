// x32 links the Kairo library (P702): on x86_64-linux-muslx32 every `thread`
// global the library touches is spelled local-exec, where it was initial-exec
// (CXXSpell::tls_model). lld relaxes an initial-exec access only in its REX.W
// movq / addq form, and x32's is a REX-less movl, so the static link stopped at
// "R_X86_64_GOTTPOFF must be used in MOVQ or ADDQ instructions only"
// (builtin::alloc_raw's scope_top). The root validates through test.k and a
// Kairo hello runs natively (CONFIG_X86_X32_ABI).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share, shell, host-linux, host-x86_64, long-tests
// RUN: rm -rf %t && python3 %S/Inputs/ksys_env_rt.py %ksys %sysgen_share %t
// RUN: echo 'env KAIRO_SYSROOT_CACHE=%t/cache %t/tc/bin/ksys --share %t/share "$@"' > %t/ksys.sh
//
// RUN: sh %t/ksys.sh ensure x86_64-linux-muslx32 > %t/path 2> %t/err
// RUN: %FileCheck %s --check-prefix=VAL < %t/err
// VAL: ksys: x86_64-linux-muslx32: validate: t.c:          built, ran, exit 7
// VAL-NEXT: ksys: x86_64-linux-muslx32: validate: t.cpp:        built, ran, exit 12
// VAL-NEXT: ksys: x86_64-linux-muslx32: validate: test.k:       built, ran, exit 0
//
// RUN: printf 'import std::io\n\nfn main() -> i32 {\n    var a: f32 = -1.5\n    io::println(f"hello x32 {a}")\n    return 3\n}\n' > %t/h.k
// RUN: %t/tc/bin/kairo %t/h.k --target=x86_64-linux-muslx32 --sysroot="$(cat %t/path)" -o %t/h --cache-dir %t/kc
// RUN: { %t/h || echo "exit $?"; } | %FileCheck %s --check-prefix=OUT
// OUT: hello x32 -1.5
// OUT-NEXT: exit 3
//
// No initial-exec access left in the objects linked: every TLS reference is
// a local-exec offset.
// RUN: find %t/kc -name '*.o' -exec %t/tc/bin/llvm-objdump -r {} + > %t/relocs
// RUN: not grep -q R_X86_64_GOTTPOFF %t/relocs
// RUN: grep -q R_X86_64_TPOFF32 %t/relocs
//
// RUN: rm -rf %t/cache %t/kc %t/share/runtimes

// The glibc stub step on its own (Compiler/Spec/SysRoot.md 4.6): every library's
// stub links with its version script, so each symbol keeps the version node the
// abilist gives it. The libc-libs stage reads each library's version list twice,
// once to write stub.map and again to pass --version-script to the link; an empty
// list on the second read links with no script, and kld refuses every versioned
// symbol ("symbol __libc_stack_end@@GLIBC_2.2.5 has undefined version").
// --libc-only stops after the libc stages, so no runtimes are built.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, kcc, ksys-share, shell, host-linux
// RUN: rm -rf %t && mkdir -p %t/share/runtimes
// RUN: for e in %sysgen_share/*; do case "$(basename "$e")" in runtimes|registry.toml) ;; *) ln -s "$e" %t/share/ ;; esac; done
// RUN: %ksys --print-runtimes-revision > %t/share/runtimes/REVISION
// RUN: python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import ksys_env; print(ksys_env.tree_sha256(sys.argv[2]))" %S/inputs %t/share/runtimes > %t/rt.sha
// RUN: sed "s/^\"runtimes\"  *= \"[0-9a-f]*\"/\"runtimes\" = \"$(cat %t/rt.sha)\"/" %sysgen_share/registry.toml > %t/share/registry.toml
// RUN: { env KAIRO_SYSROOT_CACHE=%t/cache %ksys --share %t/share build x86_64-linux-gnu-glibc2.31 --libc-only --out %t/x86 2>&1; echo "exit $?"; } > %t/out
// RUN: %FileCheck %s --check-prefix=BUILD < %t/out
// BUILD: ksys: x86_64-linux-gnu-glibc2.31: stage libc-libs
// BUILD-NOT: stub link failed
// BUILD: exit 0
//
// RUN: "$(dirname %ksys)/llvm-nm" -D %t/x86/lib/libc-2.31.so | %FileCheck %s --check-prefix=SYM
// SYM-DAG: {{ }}memcpy@@GLIBC_2.14{{$}}
// SYM-DAG: {{ }}memcpy@GLIBC_2.2.5{{$}}
// SYM-DAG: {{ }}GLIBC_2.30@@GLIBC_2.30{{$}}
//
// RUN: "$(dirname %ksys)/llvm-nm" -D %t/x86/lib/ld-2.31.so | %FileCheck %s --check-prefix=LD
// LD: {{ }}__libc_stack_end@@GLIBC_2.2.5{{$}}
//
// RUN: "$(dirname %ksys)/llvm-nm" -D %t/x86/lib/libpthread-2.31.so | %FileCheck %s --check-prefix=PTH
// PTH: {{ }}pthread_create@@GLIBC_2.2.5{{$}}
//
// RUN: rm -rf %t/cache %t/x86

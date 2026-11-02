// A host shared library linked into a default (glibc floor) build was built
// against the host's newer glibc. The link takes it with
// --allow-shlib-undefined, since the floor's libc.so stubs lack its newer
// symbol versions, and afterwards its DT_VERNEED says what the program now
// needs to run. The fixture is a libfloor.so whose VERNEED names
// libc.so.6 GLIBC_2.34, built against a stub libc.so.6 so it is the same on
// every host.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-glibc, clang
// RUN: rm -rf %t && mkdir -p %t
// RUN: %clang_c -fPIC -shared -nostdlib -fuse-ld=lld -Wl,--version-script=%S/Inputs/glibc_floor_stub.map -Wl,-soname,libc.so.6 %S/Inputs/glibc_floor_stub.c -o %t/libstubc.so
// RUN: %clang_c -fPIC -shared -nostdlib -fuse-ld=lld -Wl,-soname,libfloor.so.1 %S/Inputs/glibc_floor_lib.c -L%t -lstubc -o %t/libfloor.so

// RUN: %kairo %s -L %t -l floor --print-jobs | %FileCheck %s --check-prefix=PLAN
// PLAN: ld.lld {{.*}}--allow-shlib-undefined
// RUN: %kairo %s --print-jobs | %FileCheck %s --check-prefix=NOHOST
// NOHOST:     ld.lld
// NOHOST-NOT: --allow-shlib-undefined

// RUN: { %kairo %s -L %t -l floor -o %t/a.out 2>&1; echo "exit $?"; } | %FileCheck %s
// CHECK: warning [L001W]: 'libfloor.so.1' needs GLIBC_2.34, so this program needs glibc 2.34 or newer to run (the floor is 2.31)
// CHECK: exit 0

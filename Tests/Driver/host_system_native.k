// --native builds against this machine's own C library, headers and
// libraries in clang's native order: the bundled libc++, clang's builtin
// headers, then the host's system dirs as the C library's (-isystem), and no
// sysroot. The bundled libc++, libunwind and compiler-rt are linked by path,
// never through a -L into the bundle, whose libc would win over the host's.
// It cannot be combined with --target.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-glibc
// RUN: %kairo %s --native --print-clang-args | %FileCheck %s --check-prefix=CC1
// CC1:      clang -cc1 -triple {{[a-z0-9_]+}}-unknown-linux-gnu
// CC1-SAME: -isystem {{[^ ]*}}/include/c++/v1 -isystem {{[^ ]*}}/clang/{{[0-9]+}}/include
// CC1-SAME: -isystem /usr/include
// CC1-NOT:  -idirafter
// CC1-NOT:  -isysroot

// RUN: %kairo %s --native --print-jobs | %FileCheck %s --check-prefix=LD
// LD:      ld.lld
// LD-SAME: {{[^ ]*}}glibc2.31/lib/libc++.a {{[^ ]*}}glibc2.31/lib/libc++abi.a
// LD-SAME: libclang_rt.builtins.a
// LD-SAME: -lc
// RUN: %kairo %s --native --print-jobs | %FileCheck %s --check-prefix=NOL
// NOL:     ld.lld
// NOL-NOT: -L{{[^ ]*}}glibc2.31

// RUN: { %kairo %s --native --target=x86_64-linux-gnu --type-check-only 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=MIX
// MIX: error [U001E]: --native and --target=x86_64-linux-gnu cannot be combined
// MIX: note [U001N]: --native builds for this machine
// MIX: exit 1

// A macOS --target with no OS version gets the deployment floor its roots
// are built for (P746): clang's own default is Mac OS X 10.4, which has no
// thread-local storage, so every Kairo program failed CL001E in
// Lib/builtin's allocator. 11.0 on arm64 / arm64e, 10.15 on x86_64; a
// spelled version (or a host's darwin25.6.0) is kept. The other families'
// versionless triples are left alone (Toolchain::with_os_floor).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc
// RUN: rm -rf %t && mkdir -p %t/sdk
// RUN: printf 'int main(void) { return 0; }\n' > %t/c.c
// RUN: for t in x86_64-apple-macosx arm64-apple-macosx arm64-apple-darwin arm64e-apple-macosx \
// RUN:     x86_64-apple-macosx12.0 arm64-apple-darwin25.6.0 x86_64-unknown-freebsd; do \
// RUN:   echo "== $t"; %kcc --target=$t --sysroot=%t/sdk -### -c %t/c.c 2>&1 | grep -o -- '-triple [^ ]*' | head -1; done \
// RUN:   | %FileCheck %s
// CHECK:      == x86_64-apple-macosx
// CHECK-NEXT: -triple x86_64-apple-macosx10.15{{(.0)?$}}
// CHECK:      == arm64-apple-macosx
// CHECK-NEXT: -triple arm64-apple-macosx11.0{{(.0)?$}}
// CHECK:      == arm64-apple-darwin
// CHECK-NEXT: -triple arm64-apple-macosx11.0{{(.0)?$}}
// CHECK:      == arm64e-apple-macosx
// CHECK-NEXT: -triple arm64e-apple-macosx11.0{{(.0)?$}}
// CHECK:      == x86_64-apple-macosx12.0
// CHECK-NEXT: -triple x86_64-apple-macosx12.0{{(.0)?$}}
// CHECK:      == arm64-apple-darwin25.6.0
// CHECK-NEXT: -triple arm64-apple-darwin25.6.0
// CHECK:      == x86_64-unknown-freebsd
// CHECK-NEXT: -triple x86_64-unknown-freebsd

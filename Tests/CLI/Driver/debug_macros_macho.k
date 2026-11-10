// --debug-macros asks clang for macro debug info (-fdebug-macro). LLVM crashes emitting it
// for a Mach-O target (P774), so a macOS/darwin target keeps -g and drops the macro info;
// every other family still gets it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc
// RUN: rm -rf %t && mkdir -p %t/sdk
// RUN: printf '#define A 1\nint main(void) { return A; }\n' > %t/c.c
// RUN: for t in arm64-apple-macosx x86_64-apple-macosx x86_64-unknown-linux-musl x86_64-unknown-freebsd; do \
// RUN:   echo "== $t"; %kcc --target=$t --sysroot=%t/sdk -g -Xkairo --debug-macros -### -c %t/c.c 2>&1 \
// RUN:     | grep -c -- '-debug-info-macro' || true; done | %FileCheck %s
// CHECK:      == arm64-apple-macosx
// CHECK-NEXT: 0
// CHECK:      == x86_64-apple-macosx
// CHECK-NEXT: 0
// CHECK:      == x86_64-unknown-linux-musl
// CHECK-NEXT: {{[1-9]}}
// CHECK:      == x86_64-unknown-freebsd
// CHECK-NEXT: {{[1-9]}}

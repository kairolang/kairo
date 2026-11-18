// Apple and MSVC SDKs are never bundled, so a --target of either family with
// no sysroot found is a P008E that stops the compile before parsing, not a
// warning followed by a cascade of missing-header errors from lib/builtin.
// UNSUPPORTED: system-darwin, system-windows
// Triples with no bundled root even in a dev tree, which links every family's.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --target=i386-apple-macosx 2>&1 || true; } | %FileCheck %s --check-prefix=APPLE
// RUN: { %kairo %s --type-check-only --target=armv7-pc-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=MSVC
// RUN: { %kairo %s --type-check-only --target=i386-apple-macosx --freestanding 2>&1 || true; } | %FileCheck %s --check-prefix=FREE --allow-empty
// RUN: %kairo %s --type-check-only --target=i386-apple-macosx > /dev/null 2>&1; test $? -ne 0
// APPLE: error [P008E]: no sysroot for target 'i386-apple-macosx'
// APPLE: note [P008N]: pass --sysroot=<dir>
// APPLE-NOT: R020E
// APPLE-NOT: I957E
// MSVC: error [P008E]: no sysroot for target 'armv7-pc-windows-msvc'
// MSVC-NOT: R020E
// FREE-NOT: P008E

// --force-load loads every member of the named archive (-force_load <archive>),
// once per occurrence and in order, so a static registrar nothing references
// survives the link.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-arm64-macosx
// RUN: %kairo %s --target=arm64-apple-macosx14.0 --print-ld-args --force-load=/opt/liba.a --force-load=/opt/libb.a | %FileCheck %s --check-prefix=FL
// FL: -force_load /opt/liba.a
// FL: -force_load /opt/libb.a

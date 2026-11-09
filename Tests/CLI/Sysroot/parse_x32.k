// x32 (x86_64 code, 32-bit pointers) is a target of its own (Compiler/Spec/SysRoot.md
// section 2, wave Z4): gnux32 and muslx32 keep their environment in the name and the
// clang triple, and are never matched as plain x86_64 (the toolchain's same_target
// would). The arch is "x32", so a recipe keys it apart from x86_64; its properties
// are bits=32 with a native __int128.
fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys
// RUN: rm -rf %t && mkdir -p %t
// RUN: for t in x86_64-linux-gnux32 x86_64-unknown-linux-gnux32.2.17 x86_64-linux-muslx32 \
// RUN:     x86_64-linux-gnu; do \
// RUN:   { %ksys --share %t/none probe $t 2>/dev/null || true; } | head -2; done | %FileCheck %s --check-prefix=X32
// X32:      name:         x86_64-linux-gnux32-glibc2.31
// X32-NEXT: family:       linux-gnu
// X32-NEXT: name:         x86_64-linux-gnux32-glibc2.17
// X32-NEXT: family:       linux-gnu
// X32-NEXT: name:         x86_64-linux-muslx32
// X32-NEXT: family:       linux-musl
// X32-NEXT: name:         x86_64-linux-gnu-glibc2.31
// X32-NEXT: family:       linux-gnu

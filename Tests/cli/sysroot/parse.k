// ksys parse (Compiler/Spec/SysRoot.md section 2): a sysroot name and the
// clang triple it is built with are two fields, and either form names the
// same target. The probe table's first rows are the parse; with no share
// tree the probe then refuses (exit 2), which is what each run checks too.
//
// Every family of section 14 by name; triples in other spellings; a glibc
// name without -glibc<X.Y> taking the default; ambiguous and unknown input.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys
// RUN: rm -rf %t && mkdir -p %t
// RUN: for n in x86_64-linux-musl aarch64-linux-musl armv7-linux-musl i686-linux-musl \
// RUN:     riscv64-linux-musl riscv32-linux-musl x86_64-linux-gnu-glibc2.31 \
// RUN:     armv7-linux-gnueabihf-glibc2.31 x86_64-windows-gnu armv7-windows-gnu \
// RUN:     x86_64-unknown-freebsd aarch64-unknown-freebsd x86_64-unknown-netbsd wasm32-wasi \
// RUN:     x86_64-windows-msvc arm64e-apple-macosx; do \
// RUN:   { %ksys --share %t/none probe $n 2>/dev/null || true; } | head -4; done | %FileCheck %s --check-prefix=NAMES
// NAMES:      name:         x86_64-linux-musl
// NAMES-NEXT: family:       linux-musl
// NAMES-NEXT: provider:     musl
// NAMES:      name:         armv7-linux-musl
// NAMES:      name:         riscv32-linux-musl
// NAMES:      name:         x86_64-linux-gnu-glibc2.31
// NAMES-NEXT: family:       linux-gnu
// NAMES-NEXT: provider:     glibc
// NAMES-NEXT: libc_version: 2.31
// NAMES:      name:         armv7-linux-gnueabihf-glibc2.31
// NAMES:      name:         x86_64-windows-gnu
// NAMES-NEXT: family:       windows-gnu
// NAMES-NEXT: provider:     mingw
// NAMES:      name:         armv7-windows-gnu
// NAMES:      name:         x86_64-unknown-freebsd
// NAMES-NEXT: family:       freebsd
// NAMES-NEXT: provider:     bundle
// NAMES:      name:         aarch64-unknown-freebsd
// NAMES:      name:         x86_64-unknown-netbsd
// NAMES:      name:         wasm32-wasi
// NAMES-NEXT: family:       wasi
// NAMES:      name:         x86_64-windows-msvc
// NAMES-NEXT: family:       windows-msvc
// NAMES-NEXT: provider:     user
// NAMES:      name:         arm64e-apple-macosx
// NAMES-NEXT: family:       darwin
//
// Triples map back to names: vendor dropped or spelled, sub-arch kept, the
// eabihf environment of armv7 musl, wasip1 for wasi.
// RUN: for t in armv7-unknown-linux-musleabihf x86_64-unknown-linux-gnu x86_64-pc-windows-msvc \
// RUN:     arm64e-apple-macosx11.0 arm64-apple-darwin wasm32-wasip1 x86_64-w64-windows-gnu; do \
// RUN:   { %ksys --share %t/none probe $t 2>/dev/null || true; } | head -1; done | %FileCheck %s --check-prefix=TRIPLES
// TRIPLES:      name:         armv7-linux-musl
// TRIPLES-NEXT: name:         x86_64-linux-gnu-glibc2.31
// TRIPLES-NEXT: name:         x86_64-windows-msvc
// TRIPLES-NEXT: name:         arm64e-apple-macosx
// TRIPLES-NEXT: name:         arm64-apple-macosx
// TRIPLES-NEXT: name:         wasm32-wasi
// TRIPLES-NEXT: name:         x86_64-windows-gnu
//
// A requested glibc version is part of the name.
// RUN: { %ksys --share %t/none probe x86_64-linux-gnu-glibc2.35 2>/dev/null || true; } | head -1 | %FileCheck %s --check-prefix=GLIBC
// GLIBC: name:         x86_64-linux-gnu-glibc2.35
//
// Ambiguous input lists the candidates; unknown input says so. Both exit 2.
// RUN: %ksys --share %t/none probe x86_64-linux > %t/amb.out 2>&1; test $? -eq 2
// RUN: %FileCheck %s --check-prefix=AMBIG < %t/amb.out
// AMBIG: ksys: error [P009E]: 'x86_64-linux' is ambiguous: x86_64-linux-musl, x86_64-linux-gnu-glibc2.31
// RUN: %ksys --share %t/none probe sparc-sun-solaris > %t/unk.out 2>&1; test $? -eq 2
// RUN: %FileCheck %s --check-prefix=UNKNOWN < %t/unk.out
// UNKNOWN: ksys: error [P009E]: 'sparc-sun-solaris' is not a sysroot name, or the triple of one
//
// No share tree: refusal 2, naming where it looked and how to point elsewhere.
// RUN: %ksys --share %t/none probe x86_64-linux-musl > %t/none.out 2>&1; test $? -eq 2
// RUN: %FileCheck %s --check-prefix=NOSHARE < %t/none.out
// NOSHARE: ksys: error [P009E]: share input {{.*}}none/registry.toml missing
// NOSHARE: ksys: note [P009N]: {{.*}}KAIRO_SYSROOT_SHARE

priv fn add(a: i32, b: i32) -> i32 { return a + b }

fn main() -> i32 { return add(40, 2) }

// --- lit wiring -----------------------------------------------------------
// --emit picks the backend outputs: every TU writes one file per kind,
// side by side under --cache-dir, and only obj asks for native objects.
//
// REQUIRES: clang
// RUN: rm -rf %t.d %t.both
// RUN: %kairo %s --emit=asm,llvm-ir,llvm-bc --cache-dir %t.d
// RUN: grep -q '^main:' %t.d/emit_kinds.s
// RUN: grep -q 'define .*@main' %t.d/emit_kinds.ll
// RUN: od -An -c -N4 %t.d/emit_kinds.bc | grep -q 'B   C'
// RUN: test -f %t.d/builtin/types.s
// RUN: test -z "$(find %t.d -name '*.o')"

// -S is `--emit asm`; beside an explicit --emit it adds asm.
// RUN: %kairo %s --emit=obj -S --cache-dir %t.both
// RUN: test -f %t.both/emit_kinds.o
// RUN: test -f %t.both/emit_kinds.s

// The level reaches every kind: at -O2 the IR has no call to add left.
// RUN: rm -rf %t.o2
// RUN: %kairo %s --emit=llvm-ir -O2 --cache-dir %t.o2
// RUN: awk '/define .*@main/,/^}/' %t.o2/emit_kinds.ll | { ! grep -q call; }

// RUN: { %kairo %s --emit=ll 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U003E]: invalid --emit value 'll'; accepted: obj, asm, llvm-ir, llvm-bc
// RUN: { %kairo %s --emit=tokens 2>&1 || true; } | %FileCheck %s --check-prefix=LATER
// LATER: error [U003E]: --emit=tokens is not implemented yet

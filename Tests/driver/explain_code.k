// --explain takes a code as a diagnostic prints it. Clang's codes are keyed
// four digits wide (C0195W) but print padded to three (C195W), and the
// lookup matched the text alone, so no Clang code below 1000 resolved as
// printed. The number is the code; its padding is not.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// As printed, and as the table spells it.
// RUN: %kairo --explain C195W | %FileCheck %s --check-prefix=CLANG
// RUN: %kairo --explain C0195W | %FileCheck %s --check-prefix=CLANG
// CLANG: compound-token-split-by-macro

// A Kairo code: as printed, unpadded, over-padded.
// RUN: %kairo --explain R049E | %FileCheck %s --check-prefix=KAIRO
// RUN: %kairo --explain R49E | %FileCheck %s --check-prefix=KAIRO
// RUN: %kairo --explain R0049E | %FileCheck %s --check-prefix=KAIRO
// KAIRO: unqualified member access

// The same number under a severity it does not have is a different code.
// RUN: { %kairo --explain R049W 2>&1 || true; } | %FileCheck %s --check-prefix=UNKNOWN
// UNKNOWN: unknown diagnostic code 'R049W'

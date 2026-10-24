// Kairo's own line always carries -ffp-contract=off (FlagTranslator::
// kairo_fp_cc1: no contraction is Kairo's semantics, whatever the target's
// C++ default). A given --fp-contract comes after it and after -ffast-math,
// so the explicit flag wins (cc1 takes the last).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --fp-contract=on || true; } | %FileCheck %s --check-prefix=ON
// ON: -ffp-contract=off
// ON-SAME: -ffp-contract=on
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -ffast-math --fp-contract=off || true; } | %FileCheck %s --check-prefix=WINS
// WINS: -ffp-contract=off
// WINS-SAME: -ffp-contract=fast
// WINS-SAME: -ffp-contract=off
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN: -ffp-contract=off
// DEFN-NOT: -ffp-contract=
// DEFN-NOT: -fmath-errno

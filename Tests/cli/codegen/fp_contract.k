// Kairo's own line always carries its own -ffp-contract (FlagTranslator::
// kairo_fp_cc1), whatever the target's C++ default: `on`, contraction
// within one expression, where the target has a fused multiply-add
// (x86-64-v3), and `off` where it has none (baseline x86-64). A given
// --fp-contract comes after it and after -ffast-math, so the explicit flag
// wins (cc1 takes the last).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --fp-contract=on || true; } | %FileCheck %s --check-prefix=ON
// ON: -ffp-contract=off
// ON-SAME: -ffp-contract=on
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 --fp-contract=on || true; } | %FileCheck %s --check-prefix=FMAON
// FMAON: -ffp-contract=on
// FMAON-SAME: -ffp-contract=on
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -ffast-math --fp-contract=off || true; } | %FileCheck %s --check-prefix=WINS
// WINS: -ffp-contract=off
// WINS-SAME: -ffp-contract=fast
// WINS-SAME: -ffp-contract=off
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 -ffast-math --fp-contract=off || true; } | %FileCheck %s --check-prefix=FMAWINS
// FMAWINS: -ffp-contract=on
// FMAWINS-SAME: -ffp-contract=fast
// FMAWINS-SAME: -ffp-contract=off
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN: -ffp-contract=off
// DEFN-NOT: -ffp-contract=
// DEFN-NOT: -fmath-errno
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 || true; } | %FileCheck %s --check-prefix=FMADEFN
// FMADEFN: -ffp-contract=on
// FMADEFN-NOT: -ffp-contract=
// FMADEFN-NOT: -fmath-errno

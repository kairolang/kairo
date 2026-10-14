// --fp-contract is forwarded only when given (cc1's own default is not the
// registry's), and comes after -ffast-math so the explicit flag wins.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --fp-contract=on || true; } | %FileCheck %s --check-prefix=ON
// ON: -ffp-contract=on
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -ffast-math --fp-contract=off || true; } | %FileCheck %s --check-prefix=WINS
// WINS: -ffp-contract=fast
// WINS: -ffp-contract=off
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -ffp-contract

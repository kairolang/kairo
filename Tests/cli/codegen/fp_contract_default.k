// Kairo's own line carries its contraction default unless a flag says
// otherwise (FlagTranslator::kairo_fp_cc1): -ffp-contract=on where the
// target has a fused multiply-add (x86-64-v3), -ffp-contract=off where it
// has none (baseline x86-64). --fp-model=strict turns contraction off after
// it, and an explicit --fp-contract comes last, so it wins over the default
// and over either --fp-model. The help text names the default.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN:     -ffp-contract=off
// DEFN-NOT: -ffp-contract=
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 || true; } | %FileCheck %s --check-prefix=FMADEFN
// FMADEFN:     -ffp-contract=on
// FMADEFN-NOT: -ffp-contract=
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --fp-model=strict || true; } | %FileCheck %s --check-prefix=STRICT
// STRICT:      -ffp-contract=off
// STRICT-SAME: -ffp-contract=off
// STRICT-NOT:  -ffp-contract=
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 --fp-model=strict || true; } | %FileCheck %s --check-prefix=FMASTRICT
// FMASTRICT:      -ffp-contract=on
// FMASTRICT-SAME: -ffp-contract=off
// FMASTRICT-NOT:  -ffp-contract=
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --fp-model=strict --fp-contract=on || true; } | %FileCheck %s --check-prefix=STRICTON
// STRICTON:      -ffp-contract=off
// STRICTON-SAME: -ffp-contract=on
// STRICTON-NOT:  -ffp-contract=
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --fp-model=fast --fp-contract=off || true; } | %FileCheck %s --check-prefix=FASTOFF
// FASTOFF:      -ffp-contract=fast
// FASTOFF-SAME: -ffp-contract=off
// FASTOFF-NOT:  -ffp-contract=
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --fp-contract=off || true; } | %FileCheck %s --check-prefix=OFF
// OFF:      -ffp-contract=off
// OFF-SAME: -ffp-contract=off
// OFF-NOT:  -ffp-contract=
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 --fp-contract=off || true; } | %FileCheck %s --check-prefix=FMAOFF
// FMAOFF:      -ffp-contract=on
// FMAOFF-SAME: -ffp-contract=off
// FMAOFF-NOT:  -ffp-contract=
// RUN: { %kairo --help 2>&1 || true; } | %FileCheck %s --check-prefix=HELP
// HELP: fp-contract{{.*}}(default: on where the target has an FMA instruction, else off; wins over --fp-model)

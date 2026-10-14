// -ffast-math expands to the cc1 token set clang 22's driver makes of it, in this
// order, ending at the basic complex range.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -ffast-math || true; } | %FileCheck %s --check-prefix=FAST
// FAST: -menable-no-infs -menable-no-nans -fapprox-func -funsafe-math-optimizations -fno-signed-zeros -mreassociate -freciprocal-math -ffp-contract=fast -ffast-math -ffinite-math-only -complex-range=basic
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -ffast-math

// --fp-model=fast adds the fast-math set with the promoted complex range;
// strict turns contraction off and makes exceptions and rounding observable;
// precise is cc1's own behaviour and adds nothing. Anything else is rejected.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --fp-model=fast || true; } | %FileCheck %s --check-prefix=FAST
// FAST: -ffp-contract=fast -ffast-math -ffinite-math-only -complex-range=promoted
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --fp-model=strict || true; } | %FileCheck %s --check-prefix=STRICT
// STRICT: -ffp-contract=off -frounding-math -ffp-exception-behavior=strict -complex-range=full
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --fp-model=precise || true; } | %FileCheck %s --check-prefix=PRECISEN
// PRECISEN-NOT: -complex-range
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --fp-model=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U003E]: invalid value 'bogus' for flag '--fp-model'; accepted: precise, strict, fast

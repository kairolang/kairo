// A clang backend whose startup FAILED leaves no clang at all, so nothing
// can be type-checked: no builtin, no header. The run went on into Sema and
// buried the one real error under an R020E for every `__builtin_*` the
// builtin library names. It stops now with I006F after the cause.
// The startup fails on a word --mllvm rejects and on a target clang cannot
// make (an unknown --mtune CPU; an unknown --march is P006E before the
// startup on x86). A missing sysroot does not fail the startup
// (P008W, then the headers' own errors) and --freestanding needs none:
// neither stops at I006F.

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --mllvm=-kairo-no-such-option 2>&1 || true; } | %FileCheck %s --check-prefix=MLLVM
// MLLVM: Unknown command line argument '-kairo-no-such-option'
// MLLVM-NOT: R020E
// MLLVM: fatal [I006F]: the clang backend failed to start (the error above says why); nothing can be type-checked without it
// MLLVM-NOT: R020E

// RUN: { %kairo %s --type-check-only --mtune=kairo-no-such-cpu 2>&1 || true; } | %FileCheck %s --check-prefix=MTUNE
// MTUNE: unknown target CPU 'kairo-no-such-cpu'
// MTUNE-NOT: R020E
// MTUNE: fatal [I006F]: the clang backend failed to start
// MTUNE-NOT: R020E

// RUN: %kairo %s --type-check-only --freestanding 2>&1 | %FileCheck %s --check-prefix=FREE --allow-empty
// FREE-NOT: I006F

// RUN: { %kairo %s --type-check-only --sysroot=%t.no-such-sysroot 2>&1 || true; } | %FileCheck %s --check-prefix=NOSYS
// NOSYS: warning [P008W]: sysroot not found
// NOSYS-NOT: I006F

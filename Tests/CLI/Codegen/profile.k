// --profile fills in the optimization level and debug info the user left unsaid,
// and only when it is given: release is -O2, min-size is -Os, debug is -O0 -g.
// An explicit -O or -g/-g0 wins. Not given, nothing is implied (a plain build has
// no -g). Anything but the three is rejected.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --profile=release || true; } | %FileCheck %s --check-prefix=REL
// REL: -O2
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --profile=min-size || true; } | %FileCheck %s --check-prefix=MIN
// MIN: -Os
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --profile=debug || true; } | %FileCheck %s --check-prefix=DBG
// DBG: -debug-info-kind=
// DBG: -O0
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --profile=release -O3 || true; } | %FileCheck %s --check-prefix=O3
// O3: -O3
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --profile=debug --g0 || true; } | %FileCheck %s --check-prefix=G0
// G0: -O0
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --profile=debug --g0 || true; } | %FileCheck %s --check-prefix=G0N
// G0N-NOT: -debug-info-kind
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEF
// DEF: -O0
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -debug-info-kind
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --profile=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U003E]: invalid value 'bogus' for flag '--profile'; accepted: debug, release, min-size

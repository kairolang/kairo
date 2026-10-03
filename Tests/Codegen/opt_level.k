priv fn add(a: i32, b: i32) -> i32 { return a + b }

fn main() -> i32 {
    var s: i32 = 0
    for var i: i32 = 0; i < 10; ++i { s = add(s, i) }
    return s                                   // 45
}

// --- lit wiring -----------------------------------------------------------
// The -O level reaches clang's code generation. Before it did, every object
// was built at -O0 whatever the flag said: optnone on every function and the
// -O0 pass pipeline.
//
// REQUIRES: clang
// RUN: rm -rf %t.o0 %t.o2
// RUN: %kairo %s -c --cache-dir %t.o0
// RUN: %kairo %s -c -O2 --cache-dir %t.o2

// At -O0 the helper stays a call.
// RUN: objdump -dr --no-show-raw-insn %t.o0/opt_level.o | awk '/<main>:/,/^$/' | grep -q call

// At -O2 it is inlined and the loop folds away: no call left in main.
// RUN: objdump -dr --no-show-raw-insn %t.o2/opt_level.o | awk '/<main>:/,/^$/' | { ! grep -q call; }

// -O4 and -Ofast are not levels; the error names the accepted set.
// RUN: { %kairo %s -O4 2>&1 || true; } | %FileCheck %s --check-prefix=BADO
// RUN: { %kairo %s -Ofast 2>&1 || true; } | %FileCheck %s --check-prefix=BADO
// BADO: error [U003E]: {{.*}}accepted: -O0, -O1, -O2, -O3, -Os, -Oz, -Og, -O

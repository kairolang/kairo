// `--mcpu X` targets CPU X and tunes for it, as clang's `-march=X` (x86)
// and `-mcpu=X` do: the functions carry `"tune-cpu"="X"`, not the generic
// tuning of the driver's default line. `--mtune Y` still decides the tuning
// when it is given.

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.a %t.b %t.c
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --mcpu znver3 --cache-dir %t.a
// RUN: %FileCheck %s --check-prefix=CPU < %t.a/mcpu_tunes.ll
// CPU: "target-cpu"="znver3"
// CPU-SAME: "tune-cpu"="znver3"

// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --mcpu znver3 --mtune generic --cache-dir %t.b
// RUN: %FileCheck %s --check-prefix=TUNE < %t.b/mcpu_tunes.ll
// TUNE: "target-cpu"="znver3"
// TUNE-SAME: "tune-cpu"="generic"

// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.c
// RUN: %FileCheck %s --check-prefix=DEF < %t.c/mcpu_tunes.ll
// DEF: "target-cpu"="x86-64"
// DEF-SAME: "tune-cpu"="generic"

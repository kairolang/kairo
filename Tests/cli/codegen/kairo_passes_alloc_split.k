// alloc-split (Optimize/LLVM/AllocSplit.k) is listed after the passes it
// follows, runs above -O0 except under -Os / -Oz (it copies code), and is
// turned off by name.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --print-kairo-passes -O0 | %FileCheck %s --check-prefix=O0
// O0:      alloc-model      pipeline-start           off
// O0-NEXT: alloc-split      peephole                 off
// RUN: %kairo --print-kairo-passes -O2 | %FileCheck %s --check-prefix=O2
// O2:      alloc-model      pipeline-start           on
// O2-NEXT: alloc-split      peephole                 on
// RUN: %kairo --print-kairo-passes -Os | %FileCheck %s --check-prefix=OS
// RUN: %kairo --print-kairo-passes -Oz | %FileCheck %s --check-prefix=OS
// OS:      alloc-model      pipeline-start           on
// OS-NEXT: alloc-split      peephole                 off
// RUN: %kairo --print-kairo-passes -O3 --disable-kairo-pass=alloc-split | %FileCheck %s --check-prefix=OFF
// OFF:      alloc-model      pipeline-start           on
// OFF-NEXT: alloc-split      peephole                 off
// RUN: { %kairo --print-kairo-passes -O2 --disable-kairo-pass=no-such-pass 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U001E]: unknown Kairo pass 'no-such-pass' in --disable-kairo-pass; the passes are: spec-devirt, alloc-model, alloc-split

// --print-kairo-passes lists Kairo's own LLVM passes (Optimize/PassRegistry.k):
// each one's name, its point in LLVM's pipeline, and whether it runs at the
// command line's -O and --disable-kairo-pass. spec-devirt runs above -O0
// except under -Os / -Oz; alloc-model runs above -O0. --disable-kairo-pass
// names a pass; any other name is an error listing the passes, whether or
// not anything is printed.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --print-kairo-passes -O0 | %FileCheck %s --check-prefix=O0
// O0:      spec-devirt      pipeline-start           off
// O0-NEXT: alloc-model      pipeline-start           off
// RUN: %kairo --print-kairo-passes -O2 | %FileCheck %s --check-prefix=O2
// O2:      spec-devirt      pipeline-start           on
// O2-NEXT: alloc-model      pipeline-start           on
// RUN: %kairo --print-kairo-passes -Os | %FileCheck %s --check-prefix=OS
// OS:      spec-devirt      pipeline-start           off
// OS-NEXT: alloc-model      pipeline-start           on
// RUN: %kairo --print-kairo-passes -O3 --disable-kairo-pass=spec-devirt | %FileCheck %s --check-prefix=OFF
// OFF:      spec-devirt      pipeline-start           off
// OFF-NEXT: alloc-model      pipeline-start           on
// RUN: { %kairo --print-kairo-passes -O2 --disable-kairo-pass=no-such-pass 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// RUN: { %kairo %s --type-check-only --disable-kairo-pass=no-such-pass 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// RUN: not %kairo %s --type-check-only --disable-kairo-pass=no-such-pass
// BAD: error [U001E]: unknown Kairo pass 'no-such-pass' in --disable-kairo-pass; the passes are: spec-devirt, alloc-model
// RUN: %kairo %s --type-check-only --disable-kairo-pass=alloc-model --disable-kairo-pass spec-devirt

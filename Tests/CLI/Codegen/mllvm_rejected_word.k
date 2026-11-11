// A --mllvm word LLVM rejects fails the clang backend's startup at that point
// (P890). It used to set the failure and carry on: the instance and the
// builtin oracle were built and the backend logged "started", so it was
// failed and started at once. This pins that state (no "started" after the
// rejection) and that the run fails. It does not pin a clean user-facing
// stop: every builtin still misses into R020E, because the oracle was never
// handed out by a backend that is not ready, before the fix or after.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: not %kairo %s --type-check-only --mllvm=-bogus-word --verbose 2> %t.err
// RUN: %FileCheck %s --input-file=%t.err
// Both lines come from the startup task, one thread, in this order.
// CHECK: Unknown command line argument '-bogus-word'
// CHECK: ClangBackend: an --mllvm word was not accepted by LLVM
// CHECK-NOT: ClangBackend: started

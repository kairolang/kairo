// A --mllvm word LLVM rejects fails the clang backend's startup at that point.
// Carrying on after the failure builds the instance and the
// builtin oracle and the backend logs "started", so it is
// failed and started at once. This pins its absence (no "started" after the
// rejection) and that the run fails. It does not pin a clean user-facing
// stop: every builtin still misses into R020E, because the oracle was never
// handed out by a backend that is not ready, before the fix or after.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: not %kairo %s --type-check-only --mllvm=-bogus-word --verbose 2> %t.err
// RUN: %FileCheck %s --input-file=%t.err
// Both lines come from the startup task, one thread, in this order.
// LLVM writes its own message to stderr while the driver's log threads write
// theirs: the two can interleave, even inside a line, so the checks are
// order-free and match the part of LLVM's line that stays whole.
// CHECK-DAG: command line argument '-bogus-word'
// CHECK-DAG: ClangBackend: an --mllvm word was not accepted by LLVM
// CHECK-NOT: ClangBackend: started

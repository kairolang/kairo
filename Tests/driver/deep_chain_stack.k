// The driver's work runs on a thread with the pool workers' stack:
// a left-deep chain of `+` is walked recursively by Sema's visitors, one
// frame per term, and the entry file's Sema ran on the main thread, whose
// stack the OS sizes (8 MB on Linux): 30000 terms crashed a release build.
// Here the main thread's stack is cut to 2 MB, where 3000 terms crashed;
// on its own 32 MB thread (Support/Tuning.k WORKER_STACK_BYTES) the depth
// no longer depends on the shell's limit. Release handles 30000 terms,
// debug 7500.
//
// The input is generated: this file only drives it.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell
// RUN: python3 -c "print('fn main() -> i32 {\n    var x: i64 = ' + ' + '.join(['1'] * 3000) + '\n    return 0\n}')" > %t.k
// RUN: ulimit -s 2048 && %kairo %t.k --type-check-only

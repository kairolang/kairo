// A record of the outcomes on which a function leaves its argument
// moved-from crosses files: Inputs/cond_files/main.k imports lib.k, whose
// `push` moves its `@inout` argument only when it returns true, `put` only
// when it does not return null, and `spill` only when it panics. Each use
// in main.k on the outcome that moves is an error, with a note in lib.k;
// the use on the other outcome is not.

// RUN: cd %S/Inputs/cond_files && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=FILES --implicit-check-not="error ["
// RUN: cd %S/Inputs/cond_files && { %kairo main.k --type-check-only --sema-threads=1 2>&1 || true; } | %FileCheck %s --check-prefix=FILES --implicit-check-not="error ["
// FILES: main.k:7:16: error [SC052E]: 't' is used after being moved
// FILES: main.k:6:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// FILES: lib.k:27:18: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// FILES: main.k:20:12: error [SC052E]: 't' is used after being moved
// FILES: main.k:16:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'put', when it does not return null
// FILES: lib.k:37:18: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// FILES: main.k:29:16: error [SC052E]: 't' is used after being moved
// FILES: main.k:27:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'spill', when it panics
// FILES: lib.k:44:22: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics

// A record that carries a callee's outcome crosses files:
// Inputs/cond_carry/main.k imports lib.k, whose `try_push` returns
// `push`'s result (moved only when true) and whose `find` returns `put`'s
// (moved only when not null), and whose `spill` moves its argument only
// when it panics with `Full`. main.k tests those, stores `push`'s and
// `put`'s results in locals it tests later, and catches `spill`'s panics
// by type. Each use in main.k on the outcome that moves is an error, with
// a note in lib.k; the use on the other outcome is not.

// RUN: cd %S/Inputs/cond_carry && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=FILES --implicit-check-not="error ["
// RUN: cd %S/Inputs/cond_carry && { %kairo main.k --type-check-only --sema-threads=1 2>&1 || true; } | %FileCheck %s --check-prefix=FILES --implicit-check-not="error ["
// FILES: main.k:10:12: error [SC052E]: 't' is used after being moved
// FILES: main.k:6:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'try_push', when it returns true
// FILES: lib.k:38:12: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// FILES: main.k:17:16: error [SC052E]: 't' is used after being moved
// FILES: main.k:16:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'find', when it does not return null
// FILES: lib.k:42:55: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// FILES: main.k:28:16: error [SC052E]: 't' is used after being moved
// FILES: main.k:26:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// FILES: lib.k:21:18: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// FILES: main.k:42:12: error [SC052E]: 't' is used after being moved
// FILES: main.k:37:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'put', when it does not return null
// FILES: lib.k:31:18: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// FILES: main.k:52:16: error [SC052E]: 't' is used after being moved
// FILES: main.k:48:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'spill', when it panics
// FILES: lib.k:61:14: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics

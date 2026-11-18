// A pool worker that cannot be started ends the run with an error. The pool
// counts its workers before it starts them and waits for each at shutdown, so
// carrying on without one never returns.
//
// The wrapper runs the compiler with RLIMIT_NPROC at 1 (every pthread_create
// fails with EAGAIN) and prints a verdict: `reported` for exit status 1 with
// the worker message on stderr, `unlimited` for root (exempt from the limit).

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: host-linux
// RUN: python3 %S/inputs/no_new_threads.py %kairo %s --type-check-only --threads=4 | %FileCheck %s
// CHECK: {{^}}verdict: {{(reported|unlimited)$}}

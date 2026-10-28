// `thread` is C++ `thread_local` at every scope: a namespace-scope variable
// (on its `extern` declaration and its definition alike, which C++ requires
// to agree), a class member (`static thread_local`), and a function-local
// one (`static thread_local`, so it keeps its value across calls on the
// same thread). The run proves one instance per thread: the worker sees
// fresh copies of both the global and the function-local counter, and its
// writes never reach main's.

ffi "c" import "pthread.h"

thread hits: i32 = 0
thread const BASE = 40
static seen: i32 = 0

class Pool {
    pub thread uses: i32 = 0
}

fn bump() -> i32 {
    thread calls: i32 = 0
    calls += 1
    return calls
}

fn worker(arg: unsafe *void) -> unsafe *void {
    hits += 5                                 // its own `hits`: 0 + 5
    Pool::uses += 1                           // its own `uses`: 1
    bump()
    seen = hits * 100 + Pool::uses * 10 + bump()   // 5*100 + 1*10 + 2
    return arg
}

fn main() -> i32 {
    hits = 1
    Pool::uses = 7
    bump()
    bump()
    var tid: pthread_t
    unsafe { pthread_create(&tid as unsafe *pthread_t, &null, worker, &null) }
    pthread_join(tid, &null)
    if seen != 512 { return 1 }               // the worker saw shared state
    if hits != 1 { return 2 }                 // the worker's write reached main
    if Pool::uses != 7 { return 3 }
    if bump() != 3 { return 4 }               // main's local counter was touched
    return BASE + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=DEF
// DEF-LABEL: CODEGEN C++: {{.*}}thread_local.k
// DEF: {{^ *}}public: static thread_local signed int uses;
// DEF: {{^ *}}inline constinit thread_local signed int Pool::uses = 0;
// DEF: {{^ *}}extern thread_local signed int hits;
// DEF: {{^ *}}extern thread_local signed int const BASE;
// DEF: {{^ *}}thread_local signed int hits = 0;
// DEF: {{^ *}}thread_local signed int const BASE = 40;
// DEF: {{^ *}}static thread_local signed int calls = 0;

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 42

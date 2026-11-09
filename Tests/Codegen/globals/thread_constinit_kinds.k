// over every literal kind: a `thread` global whose initializer is a
// literal -- an integer, a negated one, a float, a bool, a char, `&null` for
// a raw pointer -- is `constinit` on its extern declaration and its
// definition alike. One initialized by a call is not: constinit there would
// be a clang error, and its TLS init wrapper is its correct cost.

thread a: i32 = 7
thread b: i64 = -3
thread c: f64 = 2.5
thread d: bool = true
thread e: char = 'k'
thread f: unsafe *i32 = &null

fn seed() -> i32 { return 4 }
thread g: i32 = seed()

fn main() -> i32 {
    if (a != 7) || (b != -3) || (c != 2.5) || (!d) || (e != 'k') || (f != &null) || (g != 4) { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: extern constinit thread_local signed int a __attribute((tls_model("local-exec")));
// CXX-DAG: extern constinit thread_local {{.*}} b __attribute((tls_model("local-exec")));
// CXX-DAG: extern constinit thread_local double c __attribute((tls_model("local-exec")));
// CXX-DAG: extern constinit thread_local bool d __attribute((tls_model("local-exec")));
// CXX-DAG: extern constinit thread_local char32_t e __attribute((tls_model("local-exec")));
// CXX-DAG: extern constinit thread_local signed int {{\*|\* }}f __attribute((tls_model("local-exec")));
// CXX-DAG: extern thread_local signed int g __attribute((tls_model("local-exec")));
// CXX-NOT: constinit thread_local signed int g

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe

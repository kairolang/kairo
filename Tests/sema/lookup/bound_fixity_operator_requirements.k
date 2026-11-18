// `++` and `--` on a value of a bounded generic type find the interface's
// marked requirement: a requirement is matched on the operator's key,
// which leaves the `l` / `r` marker out.

interface Pre {
    fn op l++(self) -> Self
}

interface Post {
    fn op r--(self) -> Self
}

interface Plain {
    fn get(self) -> i32
}

fn <T impl Pre> pre(v: T) -> T {
    var w = v
    var a = ++w
    return a
}

fn <T impl Post> post(v: T) -> T {
    var w = v
    var a = w--
    return a
}

fn <T impl Plain> none(v: T) -> T {
    var w = v
    var a = ++w
    return w
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{:(19|25):.*}}error
// DIAG: {{.*}}:31:13: error [R025E]: '++' on 'T' needs a bound that declares 'op ++'; none of the bounds of 'T' does
// DIAG-NOT: error

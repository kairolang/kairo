// `++` / `--` on a value of a bounded generic type pick the requirement of
// the fixity the use wrote: a bound that requires both `op l++` and
// `op r++` offers both under one key, and a bound that requires only the
// prefix one does not grant the postfix use.

interface Step {
    fn op l++(self) -> Self
    fn op r++(self) -> Self
}

interface Pre {
    fn op l++(self) -> Self
}

fn <T impl Step> both(v: T) -> T {
    var w = v
    var a = ++w
    var b = w++
    return b
}

fn <T impl Pre> only_prefix(v: T) -> T {
    var w = v
    var a = w++
    return a
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{:1[78]:.*}}error
// DIAG: {{.*}}:24:13: error
// DIAG-NOT: error

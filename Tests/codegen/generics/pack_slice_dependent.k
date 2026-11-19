// `...xs: T` with T a generic parameter of the function is a `[T;]` inside
// its body (functions-parameters.mdx), a dependent slice: the function is
// emitted as a template over T whose pack parameter is `Slice<T>`.

fn <T> count(...xs: T) -> usize { return xs.size() }

fn <T> first_or(d: T, ...xs: T) -> T {
    if xs.size() == 0 { return d }
    return xs[0]
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: %kairo %s --print-ir 2>/dev/null | %FileCheck %s --check-prefix=IR
// IR: template{{ ?}}<class T> {{.*}}count({{.*}}Slice<T> xs) noexcept;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe

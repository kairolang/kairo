// Function-level hints: `@hot_path` / `@cold_path` are C++'s `[[gnu::hot]]`
// / `[[gnu::cold]]`, `@pure` is `[[gnu::pure]]` (no side effects; may read
// memory), and a `const fn` is `[[gnu::const]]` (reads only its inputs). A
// declaration and its definition carry the same attribute, and clang's IR
// shows what each told the optimizer.

var counter: i32 = 3

@hot_path
fn hot(x: i32) -> i32 { return x + 1 }

@cold_path
fn cold(x: i32) -> i32 { return x - 1 }

@pure
fn peek() -> i32 { return counter }

const fn square(x: f64) -> f64 { return x * x }
const fn hyp2(a: f64, b: f64) -> f64 { return square(a) + square(b) }

@fast_call
fn quick(x: i32) -> i32 { return x * 2 }

fn main() -> i32 {
    if hot(1) != 2 { return 1 }
    if cold(1) != 0 { return 2 }
    if peek() != 3 { return 3 }
    if hyp2(3.0, 4.0) != 25.0 { return 4 }
    if quick(4) != 8 { return 5 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: {{\[\[}}gnu{{ ?}}::{{ ?}}hot{{\]\]}}{{.*}}hot(
// CXX-DAG: {{\[\[}}gnu{{ ?}}::{{ ?}}cold{{\]\]}}{{.*}}cold(
// CXX-DAG: {{\[\[}}gnu{{ ?}}::{{ ?}}pure{{\]\]}}{{.*}}peek(
// CXX-DAG: {{\[\[}}gnu{{ ?}}::{{ ?}}const{{\]\]}}{{.*}}square(
// CXX-DAG: {{\[\[}}gnu{{ ?}}::{{ ?}}const{{\]\]}}{{.*}}hyp2(

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-linux-gnu --cache-dir %t.d/ir
// RUN: %FileCheck %s --check-prefix=IR < %t.d/ir/fn_attrs.ll
// IR-DAG: define {{.*}}@_ZN8fn_attrs3hotEi({{.*}}) {{.*}}#[[HOT:[0-9]+]]
// IR-DAG: define {{.*}}@_ZN8fn_attrs4coldEi({{.*}}) {{.*}}#[[COLD:[0-9]+]]
// IR-DAG: attributes #[[HOT]] = {{{.*}}hot
// IR-DAG: attributes #[[COLD]] = {{{.*}}cold

// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe

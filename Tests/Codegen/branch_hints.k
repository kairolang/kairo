// A branch hint reaches the branch. `__builtin_expect(c, e)` is
// clang's builtin at the call site, not a call to a library function that
// wraps it: behind that call the hint weighted the callee's return and the
// caller's branch kept none. `@likely if` / `@unlikely if` are C++'s
// `[[likely]]` / `[[unlikely]]` on the then-branch. Either way the branch
// carries branch_weights at -O2 (clang drops every hint at -O0). The calls
// to undefined C functions keep each branch from folding into a select.

ffi "c" fn ext_hot(x: i32) -> i32
ffi "c" fn ext_cold(x: i32) -> i32

fn hinted_true(x: i32) -> i32 {
    if __builtin_expect(x > 10, true) { return ext_hot(x) }
    return ext_cold(x)
}
fn hinted_false(x: i32) -> i32 {
    if __builtin_expect(x > 10, false) { return ext_cold(x) }
    return ext_hot(x)
}
fn likely_if(x: i32) -> i32 {
    @likely if x > 10 { return ext_hot(x) }
    return ext_cold(x)
}
fn unlikely_if(x: i32) -> i32 {
    @unlikely if x > 10 { return ext_cold(x) } else { return ext_hot(x) }
}

fn main() -> i32 { return hinted_true(1) + hinted_false(2) + likely_if(3) + unlikely_if(4) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: if(static_cast<bool>(__builtin_expect((x> 10), true)))
// CXX: if(static_cast<bool>(__builtin_expect((x> 10), false)))
// CXX: if(x> 10){{ ?}}{{\[\[}}likely{{\]\]}}
// CXX: if(x> 10){{ ?}}{{\[\[}}unlikely{{\]\]}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.d
// RUN: %FileCheck %s --check-prefix=IR < %t.d/branch_hints.ll
// IR-LABEL: define {{.*}}@_ZN12branch_hints11hinted_trueEi(
// IR:       br i1 %{{.*}}, label %{{.*}}, label %{{.*}}, !prof ![[HOT:[0-9]+]]
// IR-LABEL: define {{.*}}@_ZN12branch_hints12hinted_falseEi(
// IR:       br i1 %{{.*}}, label %{{.*}}, label %{{.*}}, !prof ![[COLD:[0-9]+]]
// IR-LABEL: define {{.*}}@_ZN12branch_hints9likely_ifEi(
// IR:       br i1 %{{.*}}, label %{{.*}}, label %{{.*}}, !prof ![[HOT]]
// IR-LABEL: define {{.*}}@_ZN12branch_hints11unlikely_ifEi(
// IR:       br i1 %{{.*}}, label %{{.*}}, label %{{.*}}, !prof ![[COLD]]
// IR-DAG:   ![[HOT]] = !{!"branch_weights", {{.*}}i32 2000, i32 1}
// IR-DAG:   ![[COLD]] = !{!"branch_weights", {{.*}}i32 1, i32 2000}

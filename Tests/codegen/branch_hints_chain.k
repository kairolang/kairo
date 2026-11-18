// Branch hints on every branch of an if / else-if / else chain: `@likely`
// or `@unlikely` before `else` weighs that else-branch, as the one before
// the first `if` weighs its then-branch. The hint may follow the closing
// `}` on the same line or open the next one. Each branch gets C++'s
// `[[likely]]` / `[[unlikely]]`, and clang turns each into its branch's
// weights at -O2. An attribute not followed by `else` still belongs to the
// next statement.

ffi "c" fn ext_a(x: i32) -> i32
ffi "c" fn ext_b(x: i32) -> i32
ffi "c" fn ext_c(x: i32) -> i32

fn same_line(x: i32) -> i32 {
    @likely if x > 10 {
        return ext_a(x)
    } @unlikely else if x > 5 {
        return ext_b(x)
    } @unlikely else {
        return ext_c(x)
    }
}

fn next_line(x: i32) -> i32 {
    if x > 10 {
        return ext_a(x)
    }
    @unlikely else if x > 5 {
        return ext_b(x)
    }
    @likely else {
        return ext_c(x)
    }
}

fn next_statement(x: i32) -> i32 {
    var r = 0
    if x > 1 { r = ext_a(x) }
    @unlikely if x > 100 { r = ext_b(x) }
    return r
}

fn pick(x: i32) -> i32 {
    @likely if x > 10 { return 1 } @unlikely else if x > 5 { return 2 } @unlikely else { return 3 }
}

fn main() -> i32 {
    if (pick(20) != 1) || (pick(7) != 2) || (pick(0) != 3) { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: same_line(signed int x) noexcept {
// CXX: {{\[\[}}likely{{\]\]}}
// CXX: else{{ ?}}{{\[\[}}unlikely{{\]\]}}{{ ?}}if
// CXX: else{{ ?}}{{\[\[}}unlikely{{\]\]}}
// CXX-LABEL: next_line(signed int x) noexcept {
// CXX: else{{ ?}}{{\[\[}}unlikely{{\]\]}}{{ ?}}if
// CXX: else{{ ?}}{{\[\[}}likely{{\]\]}}
// CXX-LABEL: next_statement(signed int x) noexcept {
// CXX-NOT: else{{ ?}}{{\[\[}}
// CXX: {{\[\[}}unlikely{{\]\]}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.d/ir
// RUN: %FileCheck %s --check-prefix=IR < %t.d/ir/branch_hints_chain.ll
// IR-LABEL: define {{.*}}@_ZN18branch_hints_chain9same_lineEi(
// IR: !prof
// IR: !prof
// IR-LABEL: define {{.*}}@_ZN18branch_hints_chain9next_lineEi(
// IR: !prof
// IR: !prof


// Range patterns: an integer or `char` column, constant bounds (a literal, a
// negated one, a `const` / `eval` name, or a character literal), and at least
// one value in between.

const LO: i32 = 1

fn on_string(s: string) {
    match s {
        case "a".."z" { }
// DIAG: range_err.k:[[@LINE-1]]:14: error [SC126E]: a range pattern needs an integer or 'char' value, not '{{.*}}'
        default { }
    }
}

fn runtime_bounds(x: i32, lo: i32, hi: i32) {
    match x {
        case lo..=hi { }
// DIAG: range_err.k:[[@LINE-1]]:14: error [SC126E]: a range pattern bound must be a constant: a literal, or a 'const' / 'eval' name
// DIAG: range_err.k:[[@LINE-2]]:19: error [SC126E]: a range pattern bound must be a constant: a literal, or a 'const' / 'eval' name
        default { }
    }
}

fn reversed(x: i32) {
    match x {
        case 5..=1 { }
// DIAG:      range_err.k:[[@LINE-1]]:14: error [SC126E]: this range pattern matches no value
// DIAG-NEXT: range_err.k:[[@LINE-2]]:14: note [{{[A-Z0-9]+}}]: its lower bound is above its upper bound
        default { }
    }
}

fn empty_exclusive(x: i32) {
    match x {
        case 3..3 { }
// DIAG:      range_err.k:[[@LINE-1]]:14: error [SC126E]: this range pattern matches no value
// DIAG-NEXT: range_err.k:[[@LINE-2]]:14: note [{{[A-Z0-9]+}}]: '..' excludes its upper bound, so 'a..a' is empty; write 'a' or 'a..=a'
        default { }
    }
}

// The clean ones: a `const` bound, and a `char` range.
fn const_bound(x: i32) -> i32 {
    return match x {
        case LO..=9 => 1
        default     => 0
    }
}

fn letters(c: char) -> i32 {
    return match c {
        case 'a'..='z' => 1
        default        => 0
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["

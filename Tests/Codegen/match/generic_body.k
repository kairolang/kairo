// A `match` whose scrutinee has a dependent type, in a generic function and
// in a generic class's method (pattern-matching.mdx; enums-adt.mdx,
// Destructuring with match).
//
// XFAIL: *
// Ticket "[Sema/Lower] `match` inside a generic body ICEs: \"EmitIR: match
// MatchLowering left in place\"" (private/IMPORTANT/TICKETS.TXT,
// 2026-10-25). Today it type-checks and ICEs: PatternCompilation leaves no
// decision tree for a dependent scrutinee that is TESTED (a variant
// column), MatchLowering returns null and the MatchExpr reaches EmitIR.
// (A match on a `T?` with only binder rows after `null` already works.)
// When it XPASSes, delete the XFAIL -- the run below is already the real
// assertion.

enum <T> Rep {
    Some { v: T },
    None,
}

fn <T> is_none(r: Rep<T>) -> bool {
    return match r {
        case .Some(const v) => false
        case .None => true
    }
}

class <T> Holder {
    pub var r: Rep<T>
    fn Holder(self, r: Rep<T>) { self.r = r }
    fn present(const self) -> i32 {
        return match self.r {
            case .Some(const v) => 1
            case .None => 0
        }
    }
}

fn main() -> i32 {
    var r = 0
    if is_none(Rep<i32>::None) { r += 1 }
    if !is_none(Rep<i32>::Some { v: 3 }) { r += 2 }
    var h = Holder<i64>(Rep<i64>::Some { v: 9 })
    r += h.present() * 4
    return r                                    // 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7

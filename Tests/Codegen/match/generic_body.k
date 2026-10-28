// A `match` whose scrutinee has a dependent type, in a generic function and
// in a generic class's method (pattern-matching.mdx; enums-adt.mdx,
// Destructuring with match).
//
// It used to ICE ("EmitIR: match MatchLowering left in place"): the
// patterns were never resolved against a dependent scrutinee, so no decision
// tree was built. Under MONO.md D0 they are: `Rep<T>`'s variants are its
// pattern's, a payload binder reads through the instance (`v: T`), the
// match is checked for exhaustiveness here, and the tag is read through
// `__kairo_which()` because C++ picks each instance's layout (G11).

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
    var nine: i64 = 9      // a literal payload of `Rep<i64>` is its own ticket
    var h = Holder<i64>(Rep<i64>::Some { v: nine })
    r += h.present() * 4
    return r                                    // 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: __kairo_which()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7

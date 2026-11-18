// An operator on `T?` that T has too: which one `x + y` on two
// `Both?` would call is not decided by the docs (the nullable's own, as a
// method on `T?` wins over T's, or T's on narrowed operands), so the use
// is an error naming both rather than either reading. A nullable whose
// extension declares no such operator is read as its value, as before:
// `p + q` is the nullness error.

struct Both {
    var c: i32
    fn op + (self, o: Both) -> Both { return Both{ c: self.c + o.c } }
}

extend Both? {
    fn op + (self, o: Both?) -> Both? { return null }
}

// T has the operator by derivation: `<` from `op <=>`, `+` from `op +=`.
struct Cmp {
    var c: i32
    fn op <=> (self, o: Cmp) -> Ordering { return Ordering::Equal }
}

extend Cmp? { fn op < (self, o: Cmp?) -> bool { return true } }

struct Acc {
    var c: i32
    fn op += (self, o: Acc) { self.c += o.c }
}

extend Acc? { fn op + (self, o: Acc?) -> Acc? { return null } }

struct NoOp { var c: i32 }

fn f(x: Both?, y: Both?, p: NoOp?, q: NoOp?) {
    var z? = x + y
// DIAG: extension_operator_ambiguous.k:[[@LINE-1]]:14: error [SC001E]: 'op +' on 'Both?' is ambiguous: 'Both?' declares it, and 'Both' has one too; which one a nullable operand calls is not decided yet
// DIAG: extension_operator_ambiguous.k:14:5: note [I900N]: declared on 'Both?' here
    var w = p + q
// DIAG: extension_operator_ambiguous.k:[[@LINE-1]]:13: error [SC265E]: 'p' may be null here
}

fn g(a: Cmp?, b: Cmp?, x: Acc?, y: Acc?) {
    var r = a < b
// DIAG: extension_operator_ambiguous.k:[[@LINE-1]]:13: error [SC001E]: 'op <' on 'Cmp?' is ambiguous: 'Cmp?' declares it, and 'Cmp' has one too
// DIAG: extension_operator_ambiguous.k:{{[0-9]+}}:15: note [I900N]: declared on 'Cmp?' here
    var s? = x + y
// DIAG: extension_operator_ambiguous.k:[[@LINE-1]]:14: error [SC001E]: 'op +' on 'Acc?' is ambiguous: 'Acc?' declares it, and 'Acc' has one too
// DIAG: extension_operator_ambiguous.k:{{[0-9]+}}:15: note [I900N]: declared on 'Acc?' here
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["

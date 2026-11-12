// The operators an `extend T?` block still may not declare: only a
// binary operator whose operands operator typing reads as values, on the
// nullable of a record, is selected on a nullable receiver. A primitive's
// builtin operator always competes with one on its nullable; `==` would
// compete with the nullable's own comparison; `<=>` would need its derived
// relationals; unary and compound operators are typed on paths that still
// read the value. A generic block and a library container's nullable are
// not wired either. Each stays refused at its declaration (placeholder
// SC001E), with the operator a record's nullable may declare beside them.

struct Plain { var c: i32 }

extend Plain? {
    fn op == (self, o: Plain?) -> bool { return true }
// DIAG: extension_operator_refused.k:[[@LINE-1]]:5: error [SC001E]: an extension of a nullable type cannot declare an operator yet
    fn op - (self) -> Plain? { return self }
// DIAG: extension_operator_refused.k:[[@LINE-1]]:5: error [SC001E]: an extension of a nullable type cannot declare an operator yet
    fn op += (self, o: Plain?) { }
// DIAG: extension_operator_refused.k:[[@LINE-1]]:5: error [SC001E]: an extension of a nullable type cannot declare an operator yet
    fn op <=> (self, o: Plain?) -> Ordering { return Ordering::Equal }
// DIAG: extension_operator_refused.k:[[@LINE-1]]:5: error [SC001E]: an extension of a nullable type cannot declare an operator yet
    fn op * (self, o: Plain?) -> i32 { return 1 }
}

extend i32? { fn op * (self, o: i32?) -> i32? { return null } }
// DIAG: extension_operator_refused.k:[[@LINE-1]]:15: error [SC001E]: an extension of a nullable type cannot declare an operator yet

// A generic block, and a library container's nullable: not wired yet.
class <T> Box { var v: T }
extend <T> Box<T>? { fn op + (self, o: Box<T>?) -> i32 { return 1 } }
// DIAG: extension_operator_refused.k:[[@LINE-1]]:22: error [SC001E]: an extension of a nullable type cannot declare an operator yet
extend [i32]? { fn op + (self, o: [i32]?) -> i32 { return 1 } }
// DIAG: extension_operator_refused.k:[[@LINE-1]]:17: error [SC001E]: an extension of a nullable type cannot declare an operator yet

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["

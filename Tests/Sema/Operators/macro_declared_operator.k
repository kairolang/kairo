// An operator a macro body declares reaches OperatorSignatureCheck with
// TkMacroExpand tokens. The check decides by the operator's token kind
// (OperatorFacts::single_kind), which must look through the expansion as
// symbol() does: otherwise `op &&` is not refused and `op ++` is taken
// for a binary operator.

macro bad_and! { fn op && (self, o: Self) -> bool { return true } }
macro inc! { fn op ++ (self) { } }

class A {
    var x: i32
    bad_and!
    inc!
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s
// CHECK: macro_declared_operator.k:7:65: error [SC055E]: '&&' is not overloadable
// CHECK: macro_declared_operator.k:8:32: warning [SC053W]: 'op ++' does not say which form it is; prefix is assumed
// CHECK-NOT: takes exactly one operand

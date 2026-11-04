// Two pointer operands (`p != &null`, `p == q`) compare with the builtin
// operator, as in C++, where an operator function is looked up only when an
// operand has class or enumeration type ([over.match.oper]/1). ADL through
// `pc::Node*` reached the namespace's free operator templates, none viable,
// and the comparison was SC063E "no matching overload for call to 'op !='"
// (the self-host's `llvm::dyn_cast<T>(x) != &null` beside clang's
// CustomizableOptional operators).

ffi "c++" import "pointer_compare_no_operator.h"

fn f() -> bool {
    var p = pc::find(1)
    var q = pc::find(2)
    if p != &null { return true }
    return p == q
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [

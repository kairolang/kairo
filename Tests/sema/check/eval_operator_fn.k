// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// An `eval fn` that is an operator. EvalUsageChecking names every eval fn
// it checks, and an operator has no name token: the spelling asserted
// ("ImmediateTable is null in TokenText::resolve") and the compile aborted.
// CHECK-NOT: error
// CHECK-NOT: Assertion

class P {
    pub var id: u32 = 0
    eval fn op == (const self, other: P) -> bool {
        return self.id == other.id
    }
}

fn same(a: P, b: P) -> bool {
    return a == b
}

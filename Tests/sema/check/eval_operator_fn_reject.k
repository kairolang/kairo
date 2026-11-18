// An `eval fn` operator is checked like any eval fn: its body must be
// eval-able, and a call to a non-eval function in its body is an error at the call,
// not an assertion on the operator's empty name token.

fn runtime_value() -> i32 { return 1 }

class P {
    pub var id: u32 = 0
    eval fn op == (const self, other: P) -> bool {
        return runtime_value() == 1
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="Assertion" --implicit-check-not="I003E" --implicit-check-not="error ["
// CHECK: eval_operator_fn_reject.k:10:16: error [SC189E]: an eval context can call only 'eval' functions; 'runtime_value' is a function that is not 'eval'

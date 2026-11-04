// RUN: { %kairo %s --type-check-only -I %S 2>&1 || true; } | %FileCheck %s --allow-empty
//
// In an import cycle a TU's chain binding walks another TU's records, and
// the cycle runs each phase in lockstep. ChainBinding ran inside each TU's
// T, so entered at this file, lower.k bound `n->range` before this TU's T
// had resolved `LabeledStmt derives Stmt`: R025E "no member named 'range'"
// (G31, ~1400 of the self-host's R025E). Every TU's T now runs first.
// CHECK-NOT: error

import base::*

pub class LabeledStmt derives Stmt {
    pub var label: i32 = 0
}

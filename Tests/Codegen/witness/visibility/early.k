// witness/visibility/early.k -- late.k's program with the TUs the other way
// round: blind.k is checked BEFORE ea.k, so no row exists yet and the
// extension is not even indexed. It is the same error at the same use
// (the visibility rule does not depend on the order); only the reason is
// plainer, since this TU never saw the member at all.
//
// Its extensions break the not-yet-diagnosed orphan rule on purpose; see
// late.k.
import blind
import sees
fn main() -> i32 { return sees::use_a() + blind::use_b() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG:      blind.k:6:12: error [SC001E]: 'Metric' does not conform to 'Scalable'
// DIAG-NEXT: iface.k:7:9: note [I900N]: required by this bound

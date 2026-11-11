// --cmax-errors caps what is SHOWN, not what is counted. In a batch
// whose first input fills the cap, the second input's parse error is not
// printed, but it is still an error in that TU: its "this TU has errors"
// gate must stop it after the parse, exactly as it does with no cap. Before
// the fix the engine stopped counting at the cap, so the second input's gate
// compared a frozen counter against itself and the TU went on into Sema
// (its Sema dump below appeared), and the batch reported 1 error for 3.

fn main() -> i32 { var a: i32 = u1; var b: i32 = u2; return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: printf 'pub fn g() -> i32 { return 1 + ; }\n' > %t.d/second.k
// RUN: { %kairo %s %t.d/second.k --type-check-only --print-sema --cmax-errors=1 2> /dev/null || true; } | %FileCheck %s --check-prefix=GATE
// GATE: -- sema: {{.*}}cmax_errors_batch_gates.k --
// GATE-NOT: -- sema: {{.*}}second.k --
// RUN: { %kairo %s %t.d/second.k --type-check-only --cmax-errors=1 2>&1 > /dev/null || true; } | %FileCheck %s --check-prefix=SHOWN
// SHOWN: error [R020E]: use of undeclared identifier 'u1'
// SHOWN-NEXT: error [I957E]: too many errors emitted, further errors will be suppressed
// SHOWN-NOT: second.k:
//
// The totals count every error, shown or not: u1, u2 and the parse error.
// RUN: { %kairo %s %t.d/second.k --type-check-only --verbose --cmax-errors=1 2>&1 || true; } | %FileCheck %s --check-prefix=TOTAL
// TOTAL: compilation: 2 file(s): 3 error(s)
//
// The cap still hides the rest, and the exit status still fails.
// RUN: not %kairo %s %t.d/second.k --type-check-only --cmax-errors=1 2> /dev/null

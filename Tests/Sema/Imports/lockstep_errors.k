// A file with errors reports the same diagnostics whether or not it sits in
// an import cycle. Inputs/lockstep_errors/{alone,cycle}/err.k are the
// same file: an undeclared name in a method body (N) and an unknown type in
// another function's signature (T). In alone/ its import peer.k imports
// nothing; in cycle/ peer.k imports err.k back, so the two run in the
// driver's lockstep. The lockstep stops a TU only at a hard stop, not whenever a phase leaves it
// with errors: otherwise err.k would stop after N, its T never
// run, R021E never be reported, and every call peer.k made into it fail
// "parameter type is unresolved" (SC063E).

// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/lockstep_errors/alone && { %kairo err.k --type-check-only 2>&1 || true; } > %t.d/alone.txt
// RUN: cd %S/Inputs/lockstep_errors/cycle && { %kairo err.k --type-check-only 2>&1 || true; } > %t.d/cycle.txt
// RUN: %FileCheck %s --check-prefix=ERR --implicit-check-not="error [" < %t.d/alone.txt
// RUN: %FileCheck %s --check-prefix=ERR --implicit-check-not="error [" < %t.d/cycle.txt
// ERR-DAG: err.k:9:36: error [R020E]: use of undeclared identifier 'undeclared_step'
// ERR-DAG: err.k:13:28: error [R021E]: unknown type name 'Gauge'

// The cycle adds its R058W warning and notes, and nothing about err.k: the
// lines naming err.k, with the directory cut off, are the same in both.
// RUN: grep -o 'err\.k:[0-9]*:[0-9]*: error .*' %t.d/alone.txt > %t.d/alone.err
// RUN: grep -o 'err\.k:[0-9]*:[0-9]*: error .*' %t.d/cycle.txt > %t.d/cycle.err
// RUN: diff %t.d/alone.err %t.d/cycle.err

// The same with one Sema thread: the group's lockstep then runs whole on
// the driver, not split between a pool worker's front and the driver.
// RUN: cd %S/Inputs/lockstep_errors/alone && { %kairo err.k --type-check-only --sema-threads=1 2>&1 || true; } > %t.d/alone1.txt
// RUN: cd %S/Inputs/lockstep_errors/cycle && { %kairo err.k --type-check-only --sema-threads=1 2>&1 || true; } > %t.d/cycle1.txt
// RUN: %FileCheck %s --check-prefix=ERR --implicit-check-not="error [" < %t.d/alone1.txt
// RUN: %FileCheck %s --check-prefix=ERR --implicit-check-not="error [" < %t.d/cycle1.txt

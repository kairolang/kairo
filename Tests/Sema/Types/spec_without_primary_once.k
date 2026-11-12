// A specialization with no primary template is one fault, so one error
// (GH#75): the declaration's R042E. A use of the type reported a second,
// differently worded R042E ("has a specialization but no primary template
// in scope"). Whichever site is met first reports and poisons the
// specialization; the other is silent. Here the use comes first in the
// file, then a second specialization is used after its declaration.

fn early() {
    var a: Box<bool>
}

class <> Box<bool> {
    var v: bool
}

class <> Cell<i32> {
    var v: i32
}

fn late() {
    var c: Cell<i32>
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="note ["
// CHECK: spec_without_primary_once.k:12:1: error [R042E]: 'Box' is declared as a specialization, but no primary template named 'Box' is visible here
// CHECK: spec_without_primary_once.k:16:1: error [R042E]: 'Cell' is declared as a specialization, but no primary template named 'Cell' is visible here

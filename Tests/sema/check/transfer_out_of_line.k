class Marked {
    var n: i32;
    @copy
    fn Marked(self, const other: Self);
}
@copy
fn Marked::Marked(self, const other: Self) { self.n = other.n; }

class Bare {
    var n: i32;
    @move
    fn Bare(self, other: Self);
}
fn Bare::Bare(self, other: Self) { self.n = other.n; }

class Wrong {
    var n: i32;
    @copy
    fn Wrong(self, const other: Self);
}
@move
fn Wrong::Wrong(self, other: Self) { self.n = other.n; }   // expect: error R031E -- defines no declared constructor

// --- lit wiring -----------------------------------------------------------
// An out-of-line transfer constructor finds its in-class declaration whether
// or not it repeats the marker. In a member table two marked constructors
// are never merged (the one-transfer-constructor rule judges them), but an
// out-of-line definition is matched by signature with the marker's kind in
// it: repeating `@copy` still pairs, and `@move` cannot define a `@copy`.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG:      transfer_out_of_line.k:22:{{[0-9]+}}: error [R031E]: out-of-line definition of 'Wrong' does not match any declaration in 'Wrong'
// DIAG-NOT:  {{error|warning}} [

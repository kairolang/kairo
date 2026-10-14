// --cmax-notes=N keeps at most N notes on one diagnostic. A one-note
// diagnostic is untouched by a cap of 1; the trim itself needs a two-note
// diagnostic, which no stable program here produces.
class TwoCopies {
    var n: i32;
    @copy
    fn TwoCopies(self, const other: Self) = default
    @copy
    fn TwoCopies(self, const other: Self) = default
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-notes=1 2>&1 || true; } | %FileCheck %s
// CHECK: error [SC057E]: 'TwoCopies' declares more than one '@copy' transfer constructor
// CHECK-NEXT: note [{{[A-Z0-9]+}}]: the other transfer constructor is here

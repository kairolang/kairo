//  build: kairo C3-semadump-empty-member-of-for-builtin-anchor.k --print-sema --type-check-only
// version: kairo-0.1.1+dev.20260907
//
// ### Expected behavior
// Print the canonical type (i32) instead of a decl name when the anchor
// is a builtin or other non-record canonical: "[member of i32]".
//
// ### Additional context
// Source: Compiler/Sema/SemaDump.k. Confirmed live: phase: Checked, 0
// errors, but the trace section prints an empty anchor name for the
// member access: "member  .twice   -> fn twice @ ...  [member of ]" —
// blank, where a record anchor would normally print the record's name
// (e.g. "[member of Foo]"). SemaDump's trace tries to render the anchor
// decl's name, and a builtin (i32) has no decl/name to render.

extend i32 {
    fn twice(self) -> i32 {
        return self + 1
    }
}

fn use_it() {
    var x: i32 = 5
    x.twice()
}

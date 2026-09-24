//  build: kairo B8-duplicate-diagnostic-use-site-and-decl-site.k --print-sema --type-check-only
// version: kairo-0.1.1+dev.20260907
//
// ### Expected behavior
// Keep the decl-site diagnostic; demote the use-site one to a note, or
// drop it once the diagnostic table gets split into distinct codes (a
// separate, broader cleanup).
//
// ### Additional context
// Source: Compiler/Sema/Resolve/TypeResolve.k (_pick_type_candidate,
// _primary_of_spec). Confirmed live: this fires TWO separate R001E errors
// for one fault (a specialization with no primary template) one at the
// decl site ("'Box' is declared as a specialization, but no primary
// template named 'Box' is visible here") and a second, differently
// worded one at the use site ("'Box' has a specialization but no primary
// template in scope"), with a note pointing back to the decl site.

class <> Box<bool> {
    var v: bool
}

fn use_it() {
    var b: Box<bool>
}

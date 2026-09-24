//  build: kairo D3-int-literal-bits-inference-contract-undefined.k --print-sema --type-check-only --dump-type-info
// version: kairo-0.1.1+dev.20260907
// note: --dump-type-info was checked and is not implemented yet in this
// build ("-- type info: ... (not yet implemented) --"), so --print-sema's
// output doesn't surface the internal `bits` field on the integer literal
// either. This file compiles clean either way it exists to have
// something to attach a debugger/print statement to once there's a way to
// inspect the literal's inferred bit-width.
//
// ### Expected behavior
// IntData::evaluate should default to i32 width and widen only under
// context (e.g. an explicit suffix or a wider expected type).
//
// ### Additional context
// Source: literal evaluation in Compiler/Lexer/Immediate.k /
// IntData::evaluate. Per code inspection: IntData::evaluate rounds
// value_lo == 0 to 8 bits and everything else to the minimum power-of-two
// width that fits the value, while the language docs say integer literals
// default to i32. Sema will read `bits` downstream, so the mismatch
// between "minimum width that fits" and "defaults to i32" needs to be the later one, not the former.

fn f() {
    var x = 5
}

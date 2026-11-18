// Sharper B1 repro. B1's original repro used an EXPRESSION chain
// (Foo<i32>::Inner::make()), which ChainBinding resolves not
// TypeResolve::_resolve_chain, where the claimed bug lives. This puts the
// same chain in TYPE position, which is the only path through
// _resolve_chain's `!prev->generic_args.is_empty()` -> Dependent break.
// Expect (if the bug is real): `x`'s type never gets a canonical and shows
// up as dependent, in a TU with no generic context at all.

class <T> Foo {
    var v: T
    class Inner { var q: i32 }
}

fn g() {
    var x: Foo<i32>::Inner
}




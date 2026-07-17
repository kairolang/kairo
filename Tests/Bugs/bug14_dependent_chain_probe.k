/// PROBE, not a regression test: documents what the parser currently does
/// with dependent postfix chains (chains rooted in a generic-param type).
/// DependentChain (handoff section C) is NOT implemented no node marks
/// these as instantiation-dependent, and every `<...>` bracket below is
/// being committed by the tentative parse instead of deferred.
///
/// What SHOULD eventually happen (settled design):
///   - the whole chain rooted at a T-typed receiver becomes ONE
///     DependentChain node, every `<...>` stored un-committed
///   - instantiation resolves each bracket left-to-right against the
///     then-concrete type; both-parses-valid -> hard error at the bracket
///
/// Run: kairo Tests/Bugs/bug14_dependent_chain_probe.k --print-ast=tree

fn <T> probe(a: T) -> i32 {
    var b = &a

    // receiver `a` has type T: dependent member chain. Currently the `<`
    // after `get` is decided by the tentative parse, NOT marked dependent.
    a.get<i32>(10)

    // through a pointer, with the enclosing T as the generic ARG.
    b->get_lit<T>(20)

    // T-rooted static path with a const generic arg. `T::` is a dependent
    // type-path; `<20>` in expression position.
    T::static_fn<20>(30)

    return 0
}

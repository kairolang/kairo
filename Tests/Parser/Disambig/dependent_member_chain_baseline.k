// BASELINE (pre-DependentChain): dependent member chains chains rooted
// at a T-typed receiver. No DependentChain node exists yet; the `<` after
// a member is committed by the step-level tentative parse
// (_try_step_generic_args). These checks pin that baseline so changes to
// dependent-shape parsing are caught. When DependentChain lands, these
// expectations move to dependent_chain_future.k's.
//
// NOTE deep checks are intentionally loose (no exact chain-title
// strings): if this fails after a rebuild, diff against --print-ast=tree
// by hand before touching the expectations.

fn <T> probe(a: T) -> i32 {
    var b = &a
    var r1 = a.get<i32>(10)
    var r2 = b->get_lit<T>(20)
    return 0
}

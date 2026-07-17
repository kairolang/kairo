// BASELINE (pre-DependentChain): T-rooted static path with a const
// generic argument. `T::` is a dependent type-path; nothing marks it
// dependent yet the `::` step's generic args commit via the step
// tentative parse (T is not in the DisambigTable, and generic params are
// not yet bound into LexicalScope).

fn <T> probe2() -> i32 {
    var r = T::static_fn<20>(30)
    return 0
}

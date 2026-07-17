// CONTRACT for dependent postfix chains (supersedes the old DependentChain
// design from the handoff, per the simplified-resolver decision):
//
//   In postfix-member position, `name<...>` that parses as generic
//   arguments IS generic arguments. Parenthesize to force comparison.
//
// The parse shape is type-independent and identical for every
// instantiation. The dependent resolver is then just: collect the
// instantiations of a generic fn, substitute the concrete T, type-check
// the already-shaped body, and report conformance failures at the bracket
// with the concrete T and the instantiation site. No DependentChain node,
// no un-committed brackets, no re-parse at instantiation.

fn <T> probe3(a: T) -> i32 {
    var b = &a
    var r1 = a.get<i32>(10)
    var r2 = b->get_lit<T>(20)
    var r3 = T::static_fn<20>(30)
    var r4 = T::some_type<i32>(1, 2, 3).get<10>()
    return 0
}

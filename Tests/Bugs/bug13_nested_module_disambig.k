/// Regression tests for the indexer -> parser-mode merge.
///
/// 1. Nested-module scope paths: the Index-mode parser must build module trie
///    children exactly like the full parse's scope structure, so qualified
///    generic disambiguation works: `Outer::Inner::make<i32>(5)` is a generic
///    call, not a comparison chain.
/// 2. Bug 1 (genericness sentinel): a plain forward declaration must NOT mark
///    its name generic. `foo<a>(10)` parses as a comparison chain.
/// 3. Bug 2 (phantom hoists): statement-position bindings (for-headers,
///    locals) must not hoist phantom globals into the DisambigTable.
///
/// Run: kairo Tests/Bugs/bug13_nested_module_disambig.k --print-ast=tree

var scale = 3 fn <T> gen(v: T) -> T { return v }
// A generic-argument list that fails to parse is skipped by
// _sync_generic_args, which has no token budget: a budget makes a caller loop
// stop advancing on deeply nested input and the parse never finishes. The
// input below is a nested `A<A<...<2>>>...;` followed by an assignment whose
// path ends in `::<` and thirty unclosed `A<`. It parses to the two syntax
// errors and ends. lit has no per-test timeout, so a regression shows as a
// hung run.
//
A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<2>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>;
= Foo::<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<i3>

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: generic_sync_deep_nesting.k:[[@LINE-4]]:1: error [S052E]: expected expression, found '='
// CHECK: generic_sync_deep_nesting.k:[[@LINE-5]]:6: error [S054E]: expected identifier or tuple index after '::' in access expression

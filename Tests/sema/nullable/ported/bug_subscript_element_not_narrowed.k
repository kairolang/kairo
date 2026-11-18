// XFAIL: *
// A nullable reached through a subscript is not tracked: a check on it does
// not narrow it, "and the compiler says so" (nullables.mdx, Narrowing, "What
// makes it maybe null again"). For `items[i].cache` the compiler says so
// (SC265E, "it goes through a subscript ... copy it to a local"). For an
// element that is itself nullable, `xs[i]` with `xs: [i32?]`, it reports the
// bare type error SC066E ("no operator '+' for operands 'i32?' and 'i32'").

fn element(xs: [i32?], i: usize) -> i32 {
    if xs[i]? { return xs[i] + 1 } // expect: SC265E
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='warning ['
// CHECK: bug_subscript_element_not_narrowed.k:10:{{[0-9]+}}: error [SC265E]

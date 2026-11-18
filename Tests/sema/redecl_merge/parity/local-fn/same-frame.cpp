// ORACLE MAPPING: local fn == `auto name = lambda`, NOT a local function
// declaration. C++ has no local function definitions, and `void helper();`
// in a block declares the EXTERNAL ::helper -- a different entity with
// different rules. The lambda shape is the one that models the semantics,
// so choosing it IS the claim under test.
void outer() {
    auto helper = [](int x) { return 1; };
    auto helper = [](int x) { return 2; };   // expected-error: redefinition
}

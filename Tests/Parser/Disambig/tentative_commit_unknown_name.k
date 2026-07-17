// A name with NO evidence either way (not a local binding, not in the
// DisambigTable) followed by `<args>(...)` commits as a generic call via
// the tentative-parse fallback. This is what keeps unqualified IMPORTED
// generics working the local table can't see them. Known non-generic
// names never reach this path (rule 4: they commit to comparison see
// rule4_known_value_binop.k).

fn main() -> i32 {
    var u = mystery<i32>(5)
    return 0
}
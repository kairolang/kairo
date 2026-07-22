// wildcard: `id`/`Box` visible unqualified; bare `<` disambiguated via edge.
// This comment sits directly above the import on purpose: it regression-tests
// the fix for the comment-above-import S052E (orphaned-terminator) bug.
import bar::*

// `limit < 3` is the negative control (must stay a comparison).
fn use_wildcard() -> i32 {
    var a = id<i32>(1)
    var c = Box<i32>(3)
    var e = limit < 3
    return a + c.value
}

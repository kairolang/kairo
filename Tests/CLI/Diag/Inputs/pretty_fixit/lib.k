// Corpus for CLI/Diag/pretty_fixit_columns.k. Line 5 declares hidden_fn,
// on the line number of its use in use.k. No module.k is above this file,
// so a declaration with no visibility keyword is private to it.
//
fn hidden_fn() -> i32 { return 4 }

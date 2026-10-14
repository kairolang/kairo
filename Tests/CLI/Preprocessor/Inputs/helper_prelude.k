// Support file for the --force-include / --prelude tests. Not a test: Inputs
// is excluded from collection. `pub` because a wildcard import only binds
// public names, the same rule as any other import.

pub fn helper() -> i32 { return 7 }

// Source module for name_resolution.k. Two pub functions: one reached through
// a wildcard import, one through a selective aliased import.
//
// (No lit RUN line   this is corpus, not a test. Same convention as
// Tests/Sema/Imports/per_form/bar.k.)

pub fn wildcard_target() -> i32 { return 1 }

pub fn selective_target() -> i32 { return 2 }

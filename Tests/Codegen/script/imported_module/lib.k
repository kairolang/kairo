// Imported by app.k. A module runs no statements of its own (module
// initialization in import order is a later design), so the top-level
// call below is an error, reported in this file.

import std::io::println

pub fn helper() -> i32 { return 2 }

println("lib loaded")

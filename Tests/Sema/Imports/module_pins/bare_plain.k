// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: not %kairo %s --type-check-only > /dev/null 2>&1
//
// The bare `module a::b` declaration in an ordinary file, not a module.k
// (Bugs/Triage F27). It parses -- a newline or `;` ends it -- but only a
// module.k may carry one, where it names the directory as a library
// (geometry/module.k is the accepted side). Here it is an error that points
// at the block form, the way to declare a module inside a file
// (PLAN-module-pinning.md decision A: module.k only, for now).
//
// One error for the pin, nothing for the block form below it.

module text::fmt;

pub fn answer() -> i32 { return 42 }

module inner { pub fn one() -> i32 { return 1 } }   // the block form is unchanged

fn use_inner() -> i32 { return inner::one() + answer() }

// DIAG: bare_plain.k:13:1: error [R001E]: a bare `module text::fmt` is only allowed in a module.k, where it names the directory as a library
// DIAG: note {{.*}}: to declare a module here, use the block form `module text::fmt { ... }`
// DIAG-NOT: error

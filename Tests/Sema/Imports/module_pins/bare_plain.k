// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
//
// The bare `module a::b` declaration in an ordinary file, not a module.k
// (Bugs/Triage F27). It parses -- a newline or `;` ends it -- and for now
// means nothing outside module.k: no namespace, no binding. Whether it should
// be an error here instead is not decided yet; this pins today's behaviour.

module text::fmt;

pub fn answer() -> i32 { return 42 }

module inner { pub fn one() -> i32 { return 1 } }   // the block form is unchanged

fn use_inner() -> i32 { return inner::one() + answer() }

// DIAG-NOT: error

// The file keeps its own namespace; `text::fmt` names nothing.
// CXX-NOT: namespace text
// CXX: namespace bare_plain::inner {
// CXX-NOT: namespace text

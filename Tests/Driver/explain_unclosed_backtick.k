// --explain renders its markdown one line at a time, so a code span that
// the text wraps across two lines leaves a backtick with no partner on
// each line. Such a backtick prints as itself, and the characters after it
// print too: none of them is taken for the span's content.
//
// No shipped explain text wraps a span across a line, so kunit's
// TermRenderer test renders one that does, with the renderer --explain uses.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kunit
// RUN: %kunit TermRenderer | %FileCheck %s --check-prefix=SPAN
// SPAN: and a static `op
// SPAN-NEXT: delete` gives a class an allocator
// SPAN: ok TermRenderer

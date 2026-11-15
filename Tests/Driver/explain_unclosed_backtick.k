// --explain renders its markdown one line at a time, so a code span that
// the text wraps across two lines leaves a backtick with no partner on
// each line. Such a backtick prints as itself, and the characters after it
// print too: none of them is taken for the span's content.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// SC149E's text wraps `op delete` after `op.
// RUN: %kairo --explain SC149E | %FileCheck %s --check-prefix=SPAN
// SPAN: and a static `op
// SPAN-NEXT: delete`) would give a class its own allocator

// P005F's text wraps `kairo --print-targets` after kairo.
// RUN: %kairo --explain P005F | %FileCheck %s --check-prefix=TARGETS
// TARGETS: `kairo
// TARGETS: --print-targets` lists what this build can emit

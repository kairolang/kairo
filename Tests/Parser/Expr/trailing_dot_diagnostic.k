// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// A `.` with no target names the SEPARATOR. It must not claim a whitespace rule:
// there is no whitespace and no index, just a missing member name.
//
// `fn d()` is the case that used to lie. The separator's SkipNL::After advance
// looks past the line break, lands on the `2` of the NEXT statement, finds it
// non-adjacent, and used to report "no whitespace allowed ..." about two tokens
// on different lines. Each case needs its own function: a trailing `.` at the
// end of a multi-line body legitimately continues the chain onto the next line,
// which merges the cases and hides the bug.
// ERR: :14:19: error [S054E]: expected identifier or tuple index after '.' in access expression
// ERR: :15:21: error [S054E]: expected identifier or tuple index after '.' in access expression
// ERR-NOT: whitespace
fn a() { var x = 1. }
fn b() { var x = t.0. }

// rule: an omitted return type and an explicit -> void are the SAME
// type. If return_type is null for one and a void node for the other,
// _check_return_agrees must normalize before comparing.
// EXPECT-CLEAN

fn a(i32)
fn a(x: i32) -> void { }

fn b(i32) -> void
fn b(x: i32) { }

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM on purpose: the EXPECT-ERROR annotation above names an
// absolute LINE NUMBER in the code, so anything inserted above the code
// silently invalidates it.
//
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict (both accept, or both reject).
// Message text is deliberately NOT compared -- see Tests/parity_check.py.
// On failure clang is right by definition, unless the difference is a
// deliberate Kairo rule -- in which case the case belongs in kairo-only/.
//
// RUN: %parity %s
// REQUIRES: clang

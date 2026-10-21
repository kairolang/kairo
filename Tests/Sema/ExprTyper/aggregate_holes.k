// RUN: { %kairo %s --type-check-only --diag-show-ids 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// An aggregate literal whose element fails takes the element's outcome. The
// element reports; the literal is poisoned silently. Before this, a tuple,
// list, set or map with a failed element returned no type in no terminal
// state and the typer ICE'd in finish().

var t = (1..10, ..3)
// DIAG: aggregate_holes.k:[[@LINE-1]]:17: error [SC085E]: an open range is only valid as a slice index

var l = [1, ..3]
// DIAG: aggregate_holes.k:[[@LINE-1]]:13: error [SC085E]: an open range is only valid as a slice index

var s = {1, ..3}
// DIAG: aggregate_holes.k:[[@LINE-1]]:13: error [SC085E]: an open range is only valid as a slice index

var m = {1: ..3}
// DIAG: aggregate_holes.k:[[@LINE-1]]:13: error [SC085E]: an open range is only valid as a slice index

// A mismatched element poisons the literal, not just the element.
var bad = [1, "x"]
// DIAG: aggregate_holes.k:[[@LINE-1]]:15: error [SC077E]: list element of type

// DIAG-NOT: Internal Compiler Error
// DIAG-NOT: internal:

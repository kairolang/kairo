// An unparsable generic-argument list is skipped to a recovery token or the
// end of the file; at end of file the skip terminates for any number of
// remaining tokens. The input is one error, never a hang. Here the run is
// shorter than the 64-token cap.
//
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s
// CHECK: generic_sync_at_eof_reject.k:[[@LINE+3]]:7: error [S052E]: expected expression, found '<'
// CHECK-NOT: error

Foo < < Bar
